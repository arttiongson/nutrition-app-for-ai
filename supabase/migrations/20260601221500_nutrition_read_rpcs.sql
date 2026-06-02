-- Phase 3 — computed-read RPCs for the MCP server (and app).
-- SECURITY INVOKER: run as the calling user, so RLS confines them to that user's rows and
-- auth.uid() resolves to the caller. They bucket logged_at into the user's LOCAL day using
-- profiles.timezone, and return totals/targets/remaining so clients never do the math.

create or replace function public.nutrition_day(p_date date default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_tz    text;
  v_date  date;
  v_start timestamptz;
  v_end   timestamptz;
  v_entries jsonb;
  v_totals  jsonb;
  v_t       record;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select coalesce(timezone, 'UTC') into v_tz from profiles where id = v_uid;
  v_tz   := coalesce(v_tz, 'UTC');
  v_date := coalesce(p_date, (now() at time zone v_tz)::date);
  v_start := (v_date::timestamp) at time zone v_tz;          -- local midnight -> UTC instant
  v_end   := ((v_date + 1)::timestamp) at time zone v_tz;

  select coalesce(jsonb_agg(to_jsonb(e) order by e.logged_at), '[]'::jsonb)
    into v_entries
    from nutrition_entries e
   where e.user_id = v_uid and e.logged_at >= v_start and e.logged_at < v_end;

  select jsonb_build_object(
           'calories',  coalesce(sum(calories), 0),
           'protein_g', coalesce(sum(protein_g), 0),
           'carbs_g',   coalesce(sum(carbs_g), 0),
           'fat_g',     coalesce(sum(fat_g), 0))
    into v_totals
    from nutrition_entries
   where user_id = v_uid and logged_at >= v_start and logged_at < v_end;

  select calories, protein_g, carbs_g, fat_g into v_t
    from targets where user_id = v_uid order by effective_from desc limit 1;

  return jsonb_build_object(
    'date', v_date,
    'timezone', v_tz,
    'entries', v_entries,
    'totals', v_totals,
    'targets', case when v_t is null then null else
      jsonb_build_object('calories',v_t.calories,'protein_g',v_t.protein_g,'carbs_g',v_t.carbs_g,'fat_g',v_t.fat_g) end,
    'remaining', case when v_t is null then null else jsonb_build_object(
       'calories',  v_t.calories  - (v_totals->>'calories')::numeric,
       'protein_g', v_t.protein_g - (v_totals->>'protein_g')::numeric,
       'carbs_g',   v_t.carbs_g   - (v_totals->>'carbs_g')::numeric,
       'fat_g',     v_t.fat_g     - (v_totals->>'fat_g')::numeric) end
  );
end;
$$;

create or replace function public.nutrition_range(p_start date, p_end date)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_tz  text;
  v_days jsonb;
  v_avg  jsonb;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select coalesce(timezone, 'UTC') into v_tz from profiles where id = v_uid;
  v_tz := coalesce(v_tz, 'UTC');

  with per_day as (
    select (logged_at at time zone v_tz)::date as d,
           sum(calories) as cal, sum(protein_g) as p, sum(carbs_g) as c, sum(fat_g) as f
      from nutrition_entries
     where user_id = v_uid
       and logged_at >= (p_start::timestamp at time zone v_tz)
       and logged_at <  ((p_end + 1)::timestamp at time zone v_tz)
     group by 1
  )
  select jsonb_agg(jsonb_build_object('date',d,'calories',cal,'protein_g',p,'carbs_g',c,'fat_g',f) order by d),
         jsonb_build_object('calories',round(avg(cal)),'protein_g',round(avg(p),1),'carbs_g',round(avg(c),1),'fat_g',round(avg(f),1))
    into v_days, v_avg
    from per_day;

  return jsonb_build_object('start',p_start,'end',p_end,'timezone',v_tz,
                            'days',coalesce(v_days,'[]'::jsonb),'averages',v_avg);
end;
$$;
