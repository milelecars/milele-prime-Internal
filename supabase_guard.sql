-- ─────────────────────────────────────────────────────────────────────────
-- Milele Prime — shared-state write guard
--
-- WHY THIS EXISTS
-- Every browser (the Launch Tracker page AND the Tracker tab in index.html,
-- for every team member) reads and writes ONE shared row: public.state where
-- id = 'main'. A stale/cached copy of the page from before 2026-06-03 runs old
-- persistence code that overwrites that row with empty/default data — which
-- wipes everyone's tracker checkboxes (the "it clears overnight" bug).
--
-- WHAT THIS DOES
-- The current (safe) page builds stamp every write with data.writerVersion = 2.
-- This trigger REJECTS any write that:
--   1. is missing that stamp (i.e. comes from an old/stale page build), or
--   2. would erase the whole task list (trackerTeam) down to nothing.
-- So even if someone's browser is still serving the old code, it physically
-- cannot blank the shared row anymore — its save just fails harmlessly.
--
-- HOW TO APPLY
-- Supabase dashboard → SQL Editor → paste this whole file → Run. Safe to
-- re-run (idempotent). To remove later: the two DROP lines at the bottom.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.guard_state_writes()
returns trigger
language plpgsql
as $$
declare
  new_ver      int := null;
  old_team_len int := 0;
  new_team_len int := 0;
begin
  -- Parse the version stamp defensively (missing / non-numeric -> null).
  begin
    new_ver := nullif(NEW.data->>'writerVersion', '')::int;
  exception when others then
    new_ver := null;
  end;

  -- (1) Block stale page builds that don't stamp the current version.
  if new_ver is null or new_ver < 2 then
    raise exception
      'Rejected stale write (writerVersion=%). Hard-refresh the page (Ctrl+Shift+R) to load the current build.',
      coalesce(new_ver::text, 'none');
  end if;

  -- (2) Block any write that would wipe the entire task list.
  if jsonb_typeof(NEW.data->'trackerTeam') = 'array' then
    new_team_len := jsonb_array_length(NEW.data->'trackerTeam');
  end if;

  if TG_OP = 'UPDATE' then
    if jsonb_typeof(OLD.data->'trackerTeam') = 'array' then
      old_team_len := jsonb_array_length(OLD.data->'trackerTeam');
    end if;
    if old_team_len > 0 and new_team_len = 0 then
      raise exception
        'Rejected write that would erase trackerTeam (% tasks -> 0).', old_team_len;
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists guard_state_writes on public.state;
create trigger guard_state_writes
  before insert or update on public.state
  for each row execute function public.guard_state_writes();

-- ── To uninstall this guard, run these two lines: ──
-- drop trigger if exists guard_state_writes on public.state;
-- drop function if exists public.guard_state_writes();
