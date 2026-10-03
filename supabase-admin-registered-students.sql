-- Rent & Reuse — Admin / Registered Students security patch
--
-- This patch adds a server-side admin role and two protected RPC functions.
-- The browser never gets a service-role/secret key and students cannot read
-- the full students table through the admin page.
--
-- 1) Run this whole file once in Supabase SQL Editor.
-- 2) Create/sign in to the account that should be the administrator.
-- 3) Replace YOUR_ADMIN_EMAIL below and run that statement once.
-- 4) Sign out and sign back in so the new app_metadata role is in the JWT.

create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select auth.uid()) is not null
    and coalesce(
      (select auth.jwt() -> 'app_metadata' ->> 'role'),
      ''
    ) = 'admin';
$$;

revoke execute on function public.is_current_user_admin() from public, anon;
grant execute on function public.is_current_user_admin() to authenticated;


create or replace function public.get_registered_students()
returns table (
  id uuid,
  name text,
  email text,
  phone text,
  department text,
  year text,
  hostel text,
  registered_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (
    (select auth.uid()) is not null
    and coalesce(
      (select auth.jwt() -> 'app_metadata' ->> 'role'),
      ''
    ) = 'admin'
  ) then
    raise exception 'Admin access required';
  end if;

  return query
  select
    s.id,
    coalesce(s.name, au.raw_user_meta_data ->> 'name', 'Student')::text,
    coalesce(s.email, au.email)::text,
    coalesce(s.phone, au.raw_user_meta_data ->> 'phone')::text,
    s.department::text,
    s.year::text,
    s.hostel::text,
    au.created_at
  from public.students s
  join auth.users au
    on au.id = s.auth_user_id
  order by au.created_at desc;
end;
$$;

revoke execute on function public.get_registered_students() from public, anon;
grant execute on function public.get_registered_students() to authenticated;


-- -------------------------------------------------------------------------
-- Grant the administrator role to the admin account.
--
-- Replace YOUR_ADMIN_EMAIL with the exact email used for the admin account.
-- Run this only after that account already exists in Authentication > Users.
--
-- update auth.users
-- set raw_app_meta_data =
--   coalesce(raw_app_meta_data, '{}'::jsonb)
--   || '{"role":"admin"}'::jsonb
-- where lower(email) = lower('YOUR_ADMIN_EMAIL');
--
-- Then sign out and sign back in to refresh the JWT.
-- To remove admin access later, run:
--
-- update auth.users
-- set raw_app_meta_data =
--   coalesce(raw_app_meta_data, '{}'::jsonb)
--   - 'role'
-- where lower(email) = lower('YOUR_ADMIN_EMAIL');
