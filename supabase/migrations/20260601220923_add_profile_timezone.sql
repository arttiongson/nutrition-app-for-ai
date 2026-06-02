-- Phase 3 pre-req — per-user timezone.
-- The MCP read tools bucket logged_at into the user's LOCAL day ("today", a given date),
-- so we need each user's IANA timezone. RLS is unaffected; no targets recompute needed.
alter table public.profiles
  add column timezone text not null default 'UTC';

-- (IANA name, e.g. 'America/Los_Angeles'. Default 'UTC' is safe; clients/agent set the real one.)
