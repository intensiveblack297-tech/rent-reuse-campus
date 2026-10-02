-- Rent & Reuse security/UX patch
-- Run this after the main Rent & Reuse schema.

-- Allow a student to see an item involved in their own rent/borrow request,
-- even after the item becomes unavailable.
drop policy if exists "Students can view items involved in their requests"
on public.items;

create policy "Students can view items involved in their requests"
on public.items
for select
to authenticated
using (
  exists (
    select 1
    from public.requests r
    where r.item_id = public.items.id
      and (
        r.borrower_id = (select private.current_student_id())
        or r.owner_id = (select private.current_student_id())
      )
  )
);

-- Prevent a client from creating a request that points to the wrong owner,
-- and prevent changing the item/owner/borrower after creation.
create or replace function private.validate_request_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actual_owner uuid;
  caller_student uuid;
  caller_auth uuid;
begin
  caller_auth := (select auth.uid());

  select i.owner_id
    into actual_owner
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

  select s.id
    into caller_student
  from public.students s
  where s.auth_user_id = caller_auth;

  if caller_student is null then
    raise exception 'Student profile not found';
  end if;

  if tg_op = 'INSERT' then
    if new.borrower_id <> caller_student then
      raise exception 'You can only create requests for yourself';
    end if;
  else
    if new.item_id <> old.item_id
       or new.owner_id <> old.owner_id
       or new.borrower_id <> old.borrower_id then
      raise exception 'Request participants and item cannot be changed';
    end if;

    if caller_student = old.owner_id then
      if old.status = 'pending'
         and new.status not in ('accepted','rejected') then
        raise exception 'Owner can only accept or reject a pending request';
      end if;

      if old.status = 'accepted'
         and new.status <> 'completed' then
        raise exception 'Accepted requests can only be completed by the owner';
      end if;

      if old.status not in ('pending','accepted')
         and new.status <> old.status then
        raise exception 'This request is already closed';
      end if;

    elsif caller_student = old.borrower_id then
      if old.status = 'pending'
         and new.status <> 'cancelled' then
        raise exception 'Borrower can only cancel a pending request';
      end if;

      if old.status <> 'pending'
         and new.status <> old.status then
        raise exception 'Only pending requests can be cancelled';
      end if;

    else
      raise exception 'You are not part of this request';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function private.validate_request_row()
from public, anon, authenticated;

drop trigger if exists validate_request_row_trigger
on public.requests;

create trigger validate_request_row_trigger
before insert or update
on public.requests
for each row
execute function private.validate_request_row();

select 'Rent & Reuse security patch completed successfully.' as message;


-- Enable realtime request events for live in-app notifications.
alter publication supabase_realtime add table public.requests;
