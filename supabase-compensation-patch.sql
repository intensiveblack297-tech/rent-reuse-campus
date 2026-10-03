-- Rent & Reuse: product-value liability / compensation workflow
-- Run this ONCE in Supabase SQL Editor after the handover/return patch.

alter table public.items
  add column if not exists replacement_cost numeric(10,2) not null default 0;

alter table public.requests
  add column if not exists compensation_amount numeric(10,2),
  add column if not exists compensation_reason text,
  add column if not exists compensation_claimed_at timestamptz,
  add column if not exists compensation_payment_note text,
  add column if not exists compensation_payment_submitted_at timestamptz,
  add column if not exists compensation_paid_at timestamptz;

create or replace function private.validate_request_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actual_owner uuid;
  caller_student uuid;
begin
  select i.owner_id into actual_owner
  from public.items i
  where i.id = new.item_id;

  if actual_owner is null then raise exception 'The requested item does not exist'; end if;
  if new.owner_id <> actual_owner then raise exception 'Request owner does not match item owner'; end if;
  if new.borrower_id = new.owner_id then raise exception 'You cannot request your own item'; end if;

  select s.id into caller_student
  from public.students s
  where s.auth_user_id = (select auth.uid());

  if caller_student is null then raise exception 'Student profile not found'; end if;

  if tg_op = 'INSERT' then
    if new.borrower_id <> caller_student then raise exception 'You can only create requests for yourself'; end if;
    return new;
  end if;

  if new.item_id <> old.item_id
     or new.owner_id <> old.owner_id
     or new.borrower_id <> old.borrower_id then
    raise exception 'Request participants and item cannot be changed';
  end if;

  if caller_student <> old.owner_id and caller_student <> old.borrower_id then
    raise exception 'You are not part of this request';
  end if;

  if old.status = 'pending' then
    if caller_student = old.owner_id and new.status not in ('accepted','rejected') then
      raise exception 'Owner can only accept or reject a pending request';
    end if;
    if caller_student = old.borrower_id and new.status <> 'cancelled' then
      raise exception 'Borrower can only cancel a pending request';
    end if;
  elsif old.status = 'accepted' then
    if new.status not in ('accepted','active') then
      raise exception 'Approved requests can only move to active after both handover confirmations';
    end if;
  elsif old.status = 'active' then
    if caller_student = old.owner_id and new.status not in ('active','return_pending','compensation_due') then
      raise exception 'Owner can confirm return or report a compensation issue';
    end if;
    if caller_student = old.borrower_id and new.status not in ('active','return_pending') then
      raise exception 'Borrower can only mark an active item as returned';
    end if;
  elsif old.status = 'return_pending' then
    if caller_student = old.owner_id and new.status not in ('completed','compensation_due') then
      raise exception 'Owner can confirm return or report a compensation issue';
    end if;
    if caller_student = old.borrower_id and new.status <> old.status then
      raise exception 'Waiting for the owner to confirm the return';
    end if;
  elsif old.status = 'compensation_due' then
    if caller_student = old.borrower_id and new.status <> 'payment_submitted' then
      raise exception 'Borrower can only submit compensation payment after a claim';
    end if;
    if caller_student = old.owner_id and new.status <> old.status then
      raise exception 'Waiting for the borrower to submit compensation payment';
    end if;
  elsif old.status = 'payment_submitted' then
    if caller_student = old.owner_id and new.status <> 'compensation_paid' then
      raise exception 'Owner can only confirm the submitted compensation payment';
    end if;
    if caller_student = old.borrower_id and new.status <> old.status then
      raise exception 'Payment is waiting for owner confirmation';
    end if;
  else
    if new.status <> old.status then raise exception 'This request is already closed'; end if;
  end if;

  return new;
end;
$$;

create or replace function public.claim_compensation(p_request_id uuid, p_reason text)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_student uuid;
  r public.requests;
  item_value numeric(10,2);
  clean_reason text;
begin
  caller_student := (select private.current_student_id());
  clean_reason := nullif(trim(coalesce(p_reason,'')), '');

  select * into r from public.requests where id = p_request_id for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if caller_student <> r.owner_id then raise exception 'Only the item owner can report compensation'; end if;
  if r.status not in ('active','return_pending') then
    raise exception 'Compensation can only be requested while an exchange is active or awaiting return confirmation';
  end if;
  if clean_reason is null then raise exception 'Please provide a reason'; end if;

  select replacement_cost into item_value
  from public.items where id = r.item_id for update;

  if coalesce(item_value,0) <= 0 then
    raise exception 'This item does not have a replacement value. Ask the owner to set its product value first';
  end if;

  update public.requests
  set status = 'compensation_due',
      compensation_amount = item_value,
      compensation_reason = clean_reason,
      compensation_claimed_at = coalesce(compensation_claimed_at, now())
  where id = r.id;

  select * into r from public.requests where id = r.id;
  return r;
end;
$$;

create or replace function public.submit_compensation_payment(p_request_id uuid, p_payment_note text)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_student uuid;
  r public.requests;
  clean_note text;
begin
  caller_student := (select private.current_student_id());
  clean_note := nullif(trim(coalesce(p_payment_note,'')), '');

  select * into r from public.requests where id = p_request_id for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if caller_student <> r.borrower_id then raise exception 'Only the borrower can submit compensation payment'; end if;
  if r.status <> 'compensation_due' then raise exception 'There is no active compensation claim for this exchange'; end if;
  if clean_note is null then raise exception 'Please enter a payment reference or note'; end if;

  update public.requests
  set status = 'payment_submitted',
      compensation_payment_note = clean_note,
      compensation_payment_submitted_at = coalesce(compensation_payment_submitted_at, now())
  where id = r.id;

  select * into r from public.requests where id = r.id;
  return r;
end;
$$;

create or replace function public.confirm_compensation_payment(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_student uuid;
  r public.requests;
begin
  caller_student := (select private.current_student_id());

  select * into r from public.requests where id = p_request_id for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if caller_student <> r.owner_id then raise exception 'Only the item owner can confirm compensation'; end if;
  if r.status <> 'payment_submitted' then raise exception 'No submitted compensation payment is waiting for confirmation'; end if;

  update public.requests
  set status = 'compensation_paid',
      compensation_paid_at = coalesce(compensation_paid_at, now())
  where id = r.id;

  select * into r from public.requests where id = r.id;
  return r;
end;
$$;

revoke execute on function public.claim_compensation(uuid,text) from public, anon;
revoke execute on function public.submit_compensation_payment(uuid,text) from public, anon;
revoke execute on function public.confirm_compensation_payment(uuid) from public, anon;

grant execute on function public.claim_compensation(uuid,text) to authenticated;
grant execute on function public.submit_compensation_payment(uuid,text) to authenticated;
grant execute on function public.confirm_compensation_payment(uuid) to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.requests;
exception
  when duplicate_object then null;
end $$;


-- Public to signed-in campus users so Browse cards can show the liability amount
-- without exposing unrelated item columns.
create or replace function public.get_available_item_values()
returns table (id uuid, replacement_cost numeric(10,2))
language sql
stable
security definer
set search_path = ''
as $$
  select i.id, i.replacement_cost
  from public.items i
  where i.available = true;
$$;

revoke execute on function public.get_available_item_values() from public, anon;
grant execute on function public.get_available_item_values() to authenticated;
