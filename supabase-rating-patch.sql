-- Rent & Reuse — Exchange rating and feedback system
-- Run this once in Supabase SQL Editor.
-- Ratings are allowed only after an exchange is completed or compensation is paid.
-- Each student can rate the other student once per request.

create table if not exists public.exchange_ratings (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests(id) on delete cascade,
  rater_id uuid not null references public.students(id) on delete cascade,
  rated_student_id uuid not null references public.students(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  review text,
  created_at timestamptz not null default now(),
  unique(request_id, rater_id)
);

create index if not exists exchange_ratings_rated_student_idx
  on public.exchange_ratings(rated_student_id);

alter table public.exchange_ratings enable row level security;

revoke all on table public.exchange_ratings from anon, authenticated;

create or replace function public.submit_exchange_rating(
  p_request_id uuid,
  p_rating integer,
  p_review text default null
)
returns public.exchange_ratings
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_student uuid;
  r public.requests;
  target_student uuid;
  result_row public.exchange_ratings;
begin
  caller_student := (select private.current_student_id());

  if caller_student is null then
    raise exception 'Student profile not found';
  end if;

  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'Rating must be between 1 and 5';
  end if;

  select * into r
  from public.requests
  where id = p_request_id
  for update;

  if r.id is null then
    raise exception 'Exchange not found';
  end if;

  if r.status not in ('completed','compensation_paid') then
    raise exception 'You can rate only after the exchange is finished';
  end if;

  if caller_student = r.owner_id then
    target_student := r.borrower_id;
  elsif caller_student = r.borrower_id then
    target_student := r.owner_id;
  else
    raise exception 'You are not part of this exchange';
  end if;

  if exists (
    select 1 from public.exchange_ratings
    where request_id = r.id and rater_id = caller_student
  ) then
    raise exception 'You have already rated this exchange';
  end if;

  insert into public.exchange_ratings(
    request_id, rater_id, rated_student_id, rating, review
  )
  values (
    r.id, caller_student, target_student, p_rating,
    nullif(left(coalesce(p_review,''),500),'')
  )
  returning * into result_row;

  update public.students s
  set rating = (
    select round(avg(er.rating)::numeric, 1)
    from public.exchange_ratings er
    where er.rated_student_id = target_student
  )
  where s.id = target_student;

  return result_row;
end;
$$;

create or replace function public.get_my_exchange_ratings()
returns table (
  request_id uuid,
  rater_id uuid,
  rated_student_id uuid,
  rating integer,
  review text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select er.request_id, er.rater_id, er.rated_student_id,
         er.rating, er.review, er.created_at
  from public.exchange_ratings er
  where er.rater_id = (select private.current_student_id())
     or er.rated_student_id = (select private.current_student_id());
$$;

revoke execute on function public.submit_exchange_rating(uuid,integer,text) from public, anon;
revoke execute on function public.get_my_exchange_ratings() from public, anon;

grant execute on function public.submit_exchange_rating(uuid,integer,text) to authenticated;
grant execute on function public.get_my_exchange_ratings() to authenticated;

select 'Exchange rating system installed successfully.' as message;
