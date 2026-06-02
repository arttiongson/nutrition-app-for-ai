-- Phase 1.3 — Row-Level Security policies
-- Per-operation (not FOR ALL), TO authenticated, with (select auth.uid()) wrapped
-- so Postgres evaluates it once per statement (initPlan) instead of per row.
-- Ownership keys: profiles.id, goals.profile_id, nutrition_entries.user_id, targets.user_id.
--
-- USING vs WITH CHECK: SELECT=USING, INSERT=WITH CHECK, UPDATE=both, DELETE=USING.
--
-- `targets` is READ-ONLY to clients: it is written ONLY by the 1.4 trigger. The invariant
-- is "targets are derived from profile overrides, never set directly." The MCP `set_targets`
-- tool will update profile override columns, which re-fires the trigger — it never touches
-- this table directly.

-- ── profiles (creation is handled by the signup trigger; no client DELETE) ──
create policy "profiles: select own"
  on public.profiles for select to authenticated
  using ( (select auth.uid()) = id );

create policy "profiles: insert own"
  on public.profiles for insert to authenticated
  with check ( (select auth.uid()) = id );

create policy "profiles: update own"
  on public.profiles for update to authenticated
  using ( (select auth.uid()) = id )
  with check ( (select auth.uid()) = id );

-- ── goals (full CRUD, scoped to the owning profile) ──
create policy "goals: select own"
  on public.goals for select to authenticated
  using ( (select auth.uid()) = profile_id );

create policy "goals: insert own"
  on public.goals for insert to authenticated
  with check ( (select auth.uid()) = profile_id );

create policy "goals: update own"
  on public.goals for update to authenticated
  using ( (select auth.uid()) = profile_id )
  with check ( (select auth.uid()) = profile_id );

create policy "goals: delete own"
  on public.goals for delete to authenticated
  using ( (select auth.uid()) = profile_id );

-- ── nutrition_entries (full CRUD, scoped to the owner) ──
create policy "entries: select own"
  on public.nutrition_entries for select to authenticated
  using ( (select auth.uid()) = user_id );

create policy "entries: insert own"
  on public.nutrition_entries for insert to authenticated
  with check ( (select auth.uid()) = user_id );

create policy "entries: update own"
  on public.nutrition_entries for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

create policy "entries: delete own"
  on public.nutrition_entries for delete to authenticated
  using ( (select auth.uid()) = user_id );

-- ── targets (READ-ONLY to clients; written only by the 1.4 trigger) ──
create policy "targets: select own"
  on public.targets for select to authenticated
  using ( (select auth.uid()) = user_id );
