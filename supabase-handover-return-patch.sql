-- Rent & Reuse: handover + return lifecycle patch
-- Run this ONCE in Supabase SQL Editor after the existing request-access patch.

alter table public.requests
  add column if not exists owner_handover_confirmed_at timestamptz,
  add column if not exists borrower_handover_confirmed_at timestamptz,
  add column if not exists borrower_return_confirmed_at timestamptz,
  add column if not exists owner_return_confirmed_at timestamptz,
  add column if not exists completed_at timestamptz;

-- Replace the request validator so the lifecycle can safely move:
-- pending -> accepted -> active -> return_pending -> completed
-- rejected/cancelled remain closed.
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

  if actual_owner is null then
    raise exception 'The requested item does not exist';
  end if;

  if new.owner_id <> actual_owner then
    raise exception 'Request owner does not match item owner';
  end if;

  if new.borrower_id = new.owner_id then
    raise exception 'You cannot request your own item';
  end if;

  select s.id into caller_student
  from public.students s
  where s.auth_user_id = (select auth.uid());

  if caller_student is null then
    raise exception 'Student profile not found';
  end if;

  if tg_op = 'INSERT' then
    if new.borrower_id <> caller_student then
      raise exception 'You can only create requests for yourself';
    end if;
    return new;
  end if;

  if new.item_id <> old.item_id
     or new.owner_id <> old.owner_id
     or new.borrower_id <> old.borrower_id then
    raise exception 'Request participants and item cannot be changed';
  end if;

  -- Participant-specific lifecycle changes are performed by the secure RPCs below.
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
    if new.status not in ('active','return_pending') then
      raise exception 'Active exchanges can only move to return pending';
    end if;
  elsif old.status = 'return_pending' then
    if caller_student <> old.owner_id or new.status <> 'completed' then
      raise exception 'Only the owner can complete a returned exchange';
    end if;
  else
    if new.status <> old.status then
      raise exception 'This request is already closed';
    end if;
  end if;

  return new;
end;
$$;

-- Atomically approve one request and reserve the item.
create or replace function public.approve_request(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_student uuid;
  r public.requests;
  item_available boolean;
begin
  caller_student := (select private.current_student_id());

  select * into r
  from public.requests
  where id = p_request_id
  for update;

  if r.id is null then
    raise exception 'Request not found';
  end if;

  if r.owner_id <> caller_student then
    raise exception 'Only the item owner can approve this request';
  end if;

  if r.status <> 'pending' then
    raise exception 'This request is no longer pending';
  end if;

  select available into item_available
  from public.items
  where id = r.item_id
  for update;

  if coalesce(item_available,false) = false then
    raise exception 'This item is already unavailable';
  end if;

  update public.requests
  set status = 'accepted'
  where id = r.id;

  update public.items
  set available = false
  where id = r.item_id;

  update public.requests
  set status = 'rejected'
  where item_id = r.item_id
    and owner_id = r.owner_id
    and status = 'pending'
    and id <> r.id;

  select * into r from public.requests where id = r.id;
  return r;
end;
$$;

-- Confirm one side of the physical handover.
-- When both students confirm, the exchange becomes active.
create or replace function public.confirm_request_handover(p_request_id uuid)
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

  select * into r
  from public.requests
  where id = p_request_id
  for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if caller_student <> r.owner_id and caller_student <> r.borrower_id then
    raise exception 'You are not part of this exchange';
  end if;
  if r.status not in ('accepted','active') then
    raise exception 'Handover can only be confirmed after approval';
  end if;

  if caller_student = r.owner_id then
    update public.requests
    set owner_handover_confirmed_at = coalesce(owner_handover_confirmed_at, now())
    where id = r.id;
  else
    update public.requests
    set borrower_handover_confirmed_at = coalesce(borrower_handover_confirmed_at, now())
    where id = r.id;
  end if;

  update public.requests
  set status = 'active'
  where id = r.id
    and status = 'accepted'
    and owner_handover_confirmed_at is not null
    and borrower_handover_confirmed_at is not null;

  select * into r from public.requests where id = r.id;
  return r;
end;
$$;

-- Borrower marks the item returned; owner then confirms receipt.
create or replace function public.confirm_request_return(p_request_id uuid)
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

  select * into r
  from public.requests
  where id = p_request_id
  for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if caller_student <> r.owner_id and caller_student <> r.borrower_id then
    raise exception 'You are not part of this exchange';
  end if;

  if r.status = 'active' and caller_student = r.borrower_id then
    update public.requests
    set borrower_return_confirmed_at = coalesce(borrower_return_confirmed_at, now()),
        status = 'return_pending'
    where id = r.id;

  elsif r.status = 'return_pending' and caller_student = r.owner_id then
    update public.requests
    set owner_return_confirmed_at = coalesce(owner_return_confirmed_at, now()),
        completed_at = coalesce(completed_at, now()),
        status = 'completed'
    where id = r.id;

    update public.items
    set available = true
    where id = r.item_id
      and owner_id = r.owner_id;

  else
    raise exception 'Return confirmation is not available at this stage';
  end if;

  select * into r from public.requests where id = r.id;
  return r;
end;
$$;

revoke execute on function public.approve_request(uuid) from public, anon;
revoke execute on function public.confirm_request_handover(uuid) from public, anon;
revoke execute on function public.confirm_request_return(uuid) from public, anon;

grant execute on function public.approve_request(uuid) to authenticated;
grant execute on function public.confirm_request_handover(uuid) to authenticated;
grant execute on function public.confirm_request_return(uuid) to authenticated;

-- Make sure realtime can deliver the new request lifecycle updates.
do $$
begin
  alter publication supabase_realtime add table public.requests;
exception
  when duplicate_object then null;
end $$;
