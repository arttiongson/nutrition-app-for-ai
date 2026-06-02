-- Phase 1.4 — Targets computation (STORED COMPUTED, v1 = Mifflin cold-start)
-- Faithful port of art-fitness/Services/NutritionTargetService.swift:
--   1. BMR (Mifflin-St Jeor)  2. × activity factor  3. + goal adjustment
--   4. macro split → grams (P,C=4 cal/g, F=9 cal/g)  5. per-field overrides
-- A trigger inserts a fresh `targets` row (effective_from = now) whenever a profile's
-- relevant fields or a user's goals change. SECURITY DEFINER so it can write `targets`,
-- which is read-only to clients (RLS). Reads take the latest row per user.
-- NOTE: adaptive TDEE (the data-driven v2) is intentionally NOT here — see BUILD_PLAN.md.

create or replace function public.compute_and_store_targets(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p           public.profiles%rowtype;
  v_goal      public.goal_type;
  v_pp        numeric;  -- protein % of calories
  v_cp        numeric;  -- carbs %
  v_fp        numeric;  -- fat %
  v_weight_kg numeric;
  v_bmr       numeric;
  v_factor    numeric;
  v_adjust    numeric;
  v_cals      integer;
  v_protein   numeric;
  v_carbs     numeric;
  v_fat       numeric;
begin
  select * into p from public.profiles where id = p_user_id;
  if not found then
    return;
  end if;

  -- #1-priority goal drives both the calorie adjustment and the macro split
  -- (lowest priority value wins; default general_health when no goals set).
  select g.type into v_goal
  from public.goals g
  where g.profile_id = p_user_id
  order by g.priority asc, g.created_at asc
  limit 1;
  if v_goal is null then
    v_goal := 'general_health';
  end if;

  -- macro split for the goal (computed up front so a TDEE override can re-split too)
  case v_goal
    when 'muscle_gain' then v_pp := 0.30; v_cp := 0.45; v_fp := 0.25;
    when 'fat_loss'    then v_pp := 0.40; v_cp := 0.30; v_fp := 0.30;
    when 'strength'    then v_pp := 0.30; v_cp := 0.40; v_fp := 0.30;
    else                    v_pp := 0.25; v_cp := 0.45; v_fp := 0.30;  -- general_health, custom
  end case;

  if p.weight_lb is null or p.weight_lb <= 0
     or p.height_cm is null or p.height_cm <= 0
     or p.age is null or p.age <= 0 then
    -- not enough info — fall back to moderate maintenance defaults
    v_cals := 2200; v_protein := 140; v_carbs := 248; v_fat := 73;
  else
    -- 1. BMR (Mifflin-St Jeor); poundsToKilograms = 0.45359237
    v_weight_kg := p.weight_lb * 0.45359237;
    v_bmr := 10 * v_weight_kg + 6.25 * p.height_cm - 5 * p.age;
    case p.sex
      when 'male'   then v_bmr := v_bmr + 5;
      when 'female' then v_bmr := v_bmr - 161;
      else               v_bmr := v_bmr - 78;   -- prefer_not_to_say = avg(+5, -161)
    end case;

    -- 2. activity factor from training frequency
    if    p.training_days_per_week <= 0 then v_factor := 1.2;    -- sedentary
    elsif p.training_days_per_week <= 2 then v_factor := 1.375;  -- light
    elsif p.training_days_per_week <= 5 then v_factor := 1.55;   -- moderate
    else                                     v_factor := 1.6;    -- heavy (6-7+)
    end if;

    -- 3. goal calorie adjustment
    v_adjust := case v_goal
                  when 'fat_loss'    then -500   -- ~1 lb/week deficit
                  when 'muscle_gain' then 300
                  else 0
                end;

    v_cals := greatest(round(v_bmr * v_factor + v_adjust), 0)::integer;

    -- 4. calories → grams
    v_protein := round(v_cals * v_pp / 4);
    v_carbs   := round(v_cals * v_cp / 4);
    v_fat     := round(v_cals * v_fp / 9);
  end if;

  -- 5. per-field overrides. A TDEE override re-splits macros off the new calorie total
  --    first; individual macro overrides then replace their own slot.
  if p.tdee_override is not null then
    v_cals    := p.tdee_override;
    v_protein := round(v_cals * v_pp / 4);
    v_carbs   := round(v_cals * v_cp / 4);
    v_fat     := round(v_cals * v_fp / 9);
  end if;
  if p.protein_g_override is not null then v_protein := p.protein_g_override; end if;
  if p.carbs_g_override   is not null then v_carbs   := p.carbs_g_override;   end if;
  if p.fat_g_override     is not null then v_fat     := p.fat_g_override;     end if;

  insert into public.targets (user_id, calories, protein_g, carbs_g, fat_g)
  values (p_user_id, v_cals, v_protein, v_carbs, v_fat);
end;
$$;

-- ── Triggers ──────────────────────────────────────────────────────────────
-- Profiles: recompute only when a target-affecting column changes (avoids a
-- spurious targets row on e.g. a name edit). INSERT always fires (the `of`
-- clause is ignored for INSERT), so a brand-new profile gets fallback targets.
create or replace function public.profiles_recompute_targets()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.compute_and_store_targets(new.id);
  return new;
end;
$$;

create trigger profiles_targets_recompute
  after insert or update of
    weight_lb, height_cm, age, sex, training_days_per_week,
    tdee_override, protein_g_override, carbs_g_override, fat_g_override
  on public.profiles
  for each row execute function public.profiles_recompute_targets();

-- Goals: any add/remove/re-rank can change the #1 goal → recompute.
create or replace function public.goals_recompute_targets()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.compute_and_store_targets(coalesce(new.profile_id, old.profile_id));
  return null;
end;
$$;

create trigger goals_targets_recompute
  after insert or update or delete on public.goals
  for each row execute function public.goals_recompute_targets();
