-- Phase 1.2 — Schema & enums
-- Nutrition App For AI: profiles, goals, nutrition_entries, targets.
-- Ported from art-fitness SwiftData models (NutritionEntry, User, Goal).
-- RLS is ENABLED here (deny-all by default); the scoped policies land in 1.3.
-- The `targets` table is created here but POPULATED by the 1.4 trigger (stored computed).
-- No secrets in this file — safe to open-source.

-- ─────────────────────────────────────────────────────────────────────────────
-- Enums (stable domains; add values later with ALTER TYPE ... ADD VALUE)
-- ─────────────────────────────────────────────────────────────────────────────
create type meal_type        as enum ('breakfast', 'lunch', 'dinner', 'snack');
create type nutrition_source as enum ('manual', 'ai_text', 'ai_photo');
create type sex              as enum ('male', 'female', 'prefer_not_to_say');
create type goal_type        as enum ('fat_loss', 'muscle_gain', 'strength', 'general_health', 'custom');

-- ─────────────────────────────────────────────────────────────────────────────
-- Shared updated_at trigger
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- profiles  (1:1 with auth.users — the human's stats used to compute targets)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.profiles (
  id                    uuid primary key references auth.users (id) on delete cascade,
  name                  text,
  height_cm             numeric(5,1),
  weight_lb             numeric(5,1),
  age                   smallint     check (age is null or (age >= 0 and age < 150)),
  sex                   sex          not null default 'prefer_not_to_say',
  training_days_per_week smallint    not null default 0 check (training_days_per_week between 0 and 7),
  dietary_preference    text,
  -- per-field target overrides (null = use computed value)
  tdee_override         integer      check (tdee_override is null or tdee_override >= 0),
  protein_g_override    integer      check (protein_g_override is null or protein_g_override >= 0),
  carbs_g_override      integer      check (carbs_g_override is null or carbs_g_override >= 0),
  fat_g_override        integer      check (fat_g_override is null or fat_g_override >= 0),
  created_at            timestamptz  not null default now(),
  updated_at            timestamptz  not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- goals  (a profile's ranked goals; primary goal = lowest priority)
-- profile_id == auth.users.id, so RLS keys off it directly.
-- ─────────────────────────────────────────────────────────────────────────────
create table public.goals (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references public.profiles (id) on delete cascade,
  type         goal_type not null,
  custom_label text,
  priority     smallint not null default 0,
  created_at   timestamptz not null default now()
);

create index goals_profile_id_idx on public.goals (profile_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- nutrition_entries  (the core logged data — flat, zero fitness coupling)
-- user_id defaults to auth.uid() so RLS-scoped inserts don't pass it explicitly.
-- ─────────────────────────────────────────────────────────────────────────────
create table public.nutrition_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  logged_at     timestamptz not null default now(),
  meal_type     meal_type not null,
  description   text not null default '',
  calories      integer not null default 0 check (calories >= 0),
  protein_g     numeric(6,2) not null default 0 check (protein_g >= 0),
  carbs_g       numeric(6,2) not null default 0 check (carbs_g >= 0),
  fat_g         numeric(6,2) not null default 0 check (fat_g >= 0),
  source        nutrition_source not null default 'manual',
  ai_confidence numeric(4,3) check (ai_confidence is null or (ai_confidence >= 0 and ai_confidence <= 1)),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- (user_id, logged_at desc) serves both the RLS filter and day/range queries.
create index nutrition_entries_user_logged_idx
  on public.nutrition_entries (user_id, logged_at desc);

create trigger nutrition_entries_set_updated_at
  before update on public.nutrition_entries
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- targets  (STORED COMPUTED — populated by the 1.4 trigger on profile/goal change)
-- History preserved via effective_from; reads take the latest row per user.
-- ─────────────────────────────────────────────────────────────────────────────
create table public.targets (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  calories       integer not null check (calories >= 0),
  protein_g      numeric(6,2) not null check (protein_g >= 0),
  carbs_g        numeric(6,2) not null check (carbs_g >= 0),
  fat_g          numeric(6,2) not null check (fat_g >= 0),
  effective_from timestamptz not null default now(),
  created_at     timestamptz not null default now()
);

create index targets_user_effective_idx
  on public.targets (user_id, effective_from desc);

-- ─────────────────────────────────────────────────────────────────────────────
-- Signup trigger: auto-create a profile row when an auth user is created.
-- SECURITY DEFINER + empty search_path per Supabase guidance.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, name)
  values (new.id, new.raw_user_meta_data ->> 'name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────────────────────────────────────
-- Enable RLS (deny-all until 1.3 adds the scoped policies).
-- A table is never exposed without RLS, even briefly.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.profiles          enable row level security;
alter table public.goals             enable row level security;
alter table public.nutrition_entries enable row level security;
alter table public.targets           enable row level security;
