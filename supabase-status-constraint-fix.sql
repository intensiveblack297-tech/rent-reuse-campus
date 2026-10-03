-- Rent & Reuse: fix requests status constraint for full lifecycle
-- Run this once in Supabase SQL Editor.
-- The existing constraint was created before active/return/compensation statuses
-- were introduced, so valid lifecycle updates were being rejected.

alter table public.requests
  drop constraint if exists requests_status_check;

alter table public.requests
  add constraint requests_status_check
  check (
    status in (
      'pending',
      'accepted',
      'active',
      'return_pending',
      'completed',
      'rejected',
      'cancelled',
      'compensation_due',
      'payment_submitted',
      'compensation_paid'
    )
  );

select 'requests_status_check updated successfully.' as message;
