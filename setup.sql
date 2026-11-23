-- =====================================================================
-- LOTUS ORDERS v1.3 — Supabase setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to re-run: it upgrades an existing v1.1/v1.2 database and keeps all data.
-- Then create your store from the app: ⚙︎ Settings → Create store.
-- =====================================================================
-- Security model:
--   * Nobody needs an account. Each store is protected by a STORE CODE (a passphrase).
--   * Tables are locked (RLS on, no policies, no grants): the public key cannot read
--     or write them directly. Phones call only the functions below, which need the
--     store code. Only SHA-256 hashes of the code and the owner PIN are stored.
--   * Optional OWNER PIN protects Edit List, Rebuild and list restore/reset.
--     5 wrong PINs lock PIN actions for 10 minutes.
-- =====================================================================

create table if not exists public.lotus_stores (
  code_hash           text primary key,
  catalog             jsonb,
  catalog_version     integer not null default 0,
  catalog_updated_at  timestamptz,
  catalog_updated_by  text,
  draft               jsonb not null default '{}'::jsonb,
  last_order          jsonb,
  meta                jsonb not null default '{"week":0}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
alter table public.lotus_stores add column if not exists meta jsonb not null default '{"week":0}'::jsonb;
alter table public.lotus_stores add column if not exists pin_hash text;
alter table public.lotus_stores add column if not exists pin_fails integer not null default 0;
alter table public.lotus_stores add column if not exists pin_locked_until timestamptz;
alter table public.lotus_stores add column if not exists prev_week jsonb;
alter table public.lotus_stores enable row level security;
revoke all on table public.lotus_stores from anon, authenticated;

create table if not exists public.lotus_history (
  id          bigserial primary key,
  code_hash   text not null references public.lotus_stores(code_hash) on update cascade on delete cascade,
  week        integer not null,
  data        jsonb not null,
  created_at  timestamptz not null default now()
);
create index if not exists lotus_history_store_idx on public.lotus_history (code_hash, id desc);
alter table public.lotus_history enable row level security;
revoke all on table public.lotus_history from anon, authenticated;
revoke all on sequence public.lotus_history_id_seq from anon, authenticated;

-- Remove every older version of the app's functions (signatures changed over versions).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'lotus\_%' loop
    execute 'drop function ' || f.sig;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Internal helpers (not callable from the app)
-- ---------------------------------------------------------------------
create function public.lotus_hash(p_code text)
returns text language sql immutable
set search_path = public, pg_catalog
as $$ select encode(sha256(convert_to(trim(coalesce(p_code, '')), 'UTF8')), 'hex') $$;

create function public.lotus_now_ms()
returns bigint language sql volatile
as $$ select floor(extract(epoch from clock_timestamp()) * 1000)::bigint $$;

-- Returns NULL when the PIN is fine (or no PIN is set), else 'BAD_PIN' / 'PIN_LOCKED'.
-- Never raises, so failed attempts are counted even though the caller returns an error.
create function public.lotus_pin_check(p_hash text, p_pin text)
returns text language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare r public.lotus_stores;
begin
  select * into r from public.lotus_stores where code_hash = p_hash for update;
  if r.pin_hash is null then return null; end if;
  if r.pin_locked_until is not null and r.pin_locked_until > now() then return 'PIN_LOCKED'; end if;
  if public.lotus_hash('pin:' || coalesce(p_pin, '')) = r.pin_hash then
    update public.lotus_stores set pin_fails = 0, pin_locked_until = null where code_hash = p_hash;
    return null;
  end if;
  update public.lotus_stores
     set pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end,
         pin_locked_until = case when pin_fails + 1 >= 5 then now() + interval '10 minutes' else null end
   where code_hash = p_hash;
  return case when r.pin_fails + 1 >= 5 then 'PIN_LOCKED' else 'BAD_PIN' end;
end $$;

-- ---------------------------------------------------------------------
-- Read everything for one store.
-- ---------------------------------------------------------------------
create function public.lotus_get_state(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_catalog
as $$
declare r public.lotus_stores;
begin
  select * into r from public.lotus_stores where code_hash = public.lotus_hash(p_code);
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  return jsonb_build_object(
    'catalog', r.catalog,
    'catalogVersion', r.catalog_version,
    'catalogUpdatedAt', r.catalog_updated_at,
    'catalogUpdatedBy', r.catalog_updated_by,
    'draft', r.draft,
    'lastOrder', r.last_order,
    'meta', r.meta,
    'hasPin', r.pin_hash is not null,
    'canUndo', r.prev_week is not null
               and coalesce((r.meta ->> 'rebuiltAt')::bigint, 0) > public.lotus_now_ms() - 15 * 60 * 1000,
    'serverTime', now()
  );
end $$;

-- ---------------------------------------------------------------------
-- Merge per-product changes into this week's shared order.
-- Entry: {n: on order, q: qty, d: done, x: couldn't get, c: carried over,
--         t: timestamp ms, b: name, v: device}. Newest timestamp wins per product.
-- Also records when every item on the order is handled (done or couldn't get).
-- ---------------------------------------------------------------------
create function public.lotus_patch_draft(p_code text, p_patch jsonb, p_week integer, p_by text default '')
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
  h text := public.lotus_hash(p_code);
  cur jsonb; m jsonb; k text; v jsonb; n boolean; d boolean; on_cnt int; open_cnt int;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'BAD_PATCH'; end if;
  if octet_length(p_patch::text) > 100000 then raise exception 'PATCH_TOO_LARGE'; end if;
  select draft, meta into cur, m from public.lotus_stores where code_hash = h for update;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  if coalesce((m ->> 'week')::integer, 0) <> coalesce(p_week, -1) then raise exception 'WEEK_CHANGED'; end if;

  for k, v in select key, value from jsonb_each(p_patch) loop
    continue when jsonb_typeof(v) <> 'object' or length(k) > 60;
    if cur ? k and coalesce((cur -> k ->> 't')::numeric, 0) > coalesce((v ->> 't')::numeric, 0) then continue; end if;
    n := coalesce((v ->> 'n')::boolean, false);
    d := n and coalesce((v ->> 'd')::boolean, false);
    cur := cur || jsonb_build_object(k, jsonb_build_object(
      'n', n, 'q', left(coalesce(v ->> 'q', ''), 20), 'd', d,
      'x', n and not d and coalesce((v ->> 'x')::boolean, false),
      'c', n and coalesce((v ->> 'c')::boolean, false),
      't', coalesce((v ->> 't')::numeric, 0),
      'b', left(coalesce(nullif(v ->> 'b', ''), p_by, ''), 40),
      'v', left(coalesce(v ->> 'v', ''), 40)));
  end loop;

  select count(*) filter (where (e.value ->> 'n')::boolean),
         count(*) filter (where (e.value ->> 'n')::boolean and not coalesce((e.value ->> 'd')::boolean, false)
                                                   and not coalesce((e.value ->> 'x')::boolean, false))
    into on_cnt, open_cnt from jsonb_each(cur) e;
  if on_cnt > 0 and open_cnt = 0 then
    if m ->> 'doneAt' is null then
      m := m || jsonb_build_object('doneAt', public.lotus_now_ms(), 'doneBy', left(coalesce(p_by, ''), 40));
    end if;
  else
    m := m - 'doneAt' - 'doneBy';
  end if;

  update public.lotus_stores set draft = cur, meta = m, updated_at = now() where code_hash = h;
  return cur;
end $$;

-- ---------------------------------------------------------------------
-- Save the product list (owner PIN required if one is set).
-- Returns {"version": n} or {"error": "BAD_PIN" | "PIN_LOCKED"}.
-- ---------------------------------------------------------------------
create function public.lotus_save_catalog(p_code text, p_catalog jsonb, p_base_version integer, p_by text default '', p_pin text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code); ver integer; e text;
begin
  if p_catalog is null or jsonb_typeof(p_catalog -> 'items') <> 'array' then raise exception 'BAD_CATALOG'; end if;
  if octet_length(p_catalog::text) > 200000 then raise exception 'CATALOG_TOO_LARGE'; end if;
  select catalog_version into ver from public.lotus_stores where code_hash = h for update;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  if ver > 0 then -- the very first save (seeding an empty store) needs no PIN
    e := public.lotus_pin_check(h, p_pin);
    if e is not null then return jsonb_build_object('error', e); end if;
  end if;
  if ver <> coalesce(p_base_version, -1) then raise exception 'CATALOG_CONFLICT'; end if;
  update public.lotus_stores
     set catalog = p_catalog, catalog_version = ver + 1, catalog_updated_at = now(),
         catalog_updated_by = left(coalesce(p_by, ''), 40), updated_at = now()
   where code_hash = h;
  return jsonb_build_object('version', ver + 1);
end $$;

-- ---------------------------------------------------------------------
-- Send Order: mark this week's order ready (alerts the other phones).
-- ---------------------------------------------------------------------
create function public.lotus_mark_ready(p_code text, p_week integer, p_by text, p_device text, p_count integer, p_last jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code); m jsonb;
begin
  if p_last is not null and (jsonb_typeof(p_last -> 'items') <> 'object' or octet_length(p_last::text) > 50000) then raise exception 'BAD_ORDER'; end if;
  select meta into m from public.lotus_stores where code_hash = h for update;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  if coalesce((m ->> 'week')::integer, 0) <> coalesce(p_week, -1) then raise exception 'WEEK_CHANGED'; end if;
  update public.lotus_stores
     set meta = m || jsonb_build_object('readyAt', public.lotus_now_ms(), 'readyBy', left(coalesce(p_by, ''), 40),
                                        'readyDev', left(coalesce(p_device, ''), 40),
                                        'readyCount', greatest(0, least(coalesce(p_count, 0), 10000))),
         last_order = coalesce(p_last, last_order), updated_at = now()
   where code_hash = h;
  return public.lotus_get_state(p_code);
end $$;

-- ---------------------------------------------------------------------
-- Rebuild: close this week into history and start a new one.
-- "Couldn't get" items carry over to the new week. Undo is possible for 15 min.
-- p_items: the closing week's items as the app shows them [{id,name,q,d,x}].
-- ---------------------------------------------------------------------
create function public.lotus_rebuild(p_code text, p_by text, p_device text, p_last jsonb, p_items jsonb default '[]'::jsonb, p_pin text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
  h text := public.lotus_hash(p_code); r public.lotus_stores; e text; carry jsonb := '{}'::jsonb;
  k text; v jsonb; now_ms bigint := public.lotus_now_ms(); hid bigint; wk integer;
begin
  if p_last is not null and (jsonb_typeof(p_last -> 'items') <> 'object' or octet_length(p_last::text) > 50000) then raise exception 'BAD_ORDER'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or octet_length(p_items::text) > 100000 then p_items := '[]'::jsonb; end if;
  select * into r from public.lotus_stores where code_hash = h;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  e := public.lotus_pin_check(h, p_pin);
  if e is not null then return jsonb_build_object('error', e); end if;
  select * into r from public.lotus_stores where code_hash = h for update;
  wk := coalesce((r.meta ->> 'week')::integer, 0);

  for k, v in select key, value from jsonb_each(r.draft) loop
    if coalesce((v ->> 'n')::boolean, false) and coalesce((v ->> 'x')::boolean, false) then
      carry := carry || jsonb_build_object(k, jsonb_build_object('n', true, 'q', coalesce(v ->> 'q', ''), 'd', false,
                 'x', false, 'c', true, 't', now_ms, 'b', left(coalesce(p_by, ''), 40), 'v', left(coalesce(p_device, ''), 40)));
    end if;
  end loop;

  if jsonb_array_length(p_items) > 0 then
    insert into public.lotus_history (code_hash, week, data) values (h, wk, jsonb_build_object(
      'week', wk, 'startedAt', coalesce((r.meta ->> 'rebuiltAt')::bigint, floor(extract(epoch from r.created_at) * 1000)::bigint),
      'endedAt', now_ms, 'sentAt', r.meta -> 'readyAt', 'sentBy', r.meta -> 'readyBy', 'sentCount', r.meta -> 'readyCount',
      'doneAt', r.meta -> 'doneAt', 'doneBy', r.meta -> 'doneBy', 'rebuiltBy', left(coalesce(p_by, ''), 40),
      'items', p_items)) returning id into hid;
  end if;

  update public.lotus_stores
     set prev_week = jsonb_build_object('draft', r.draft, 'meta', r.meta, 'lastOrder', r.last_order, 'historyId', hid),
         meta = jsonb_build_object('week', wk + 1, 'rebuiltAt', now_ms, 'rebuiltBy', left(coalesce(p_by, ''), 40),
                                   'rebuiltDev', left(coalesce(p_device, ''), 40)),
         draft = carry,
         last_order = coalesce(p_last, last_order),
         updated_at = now()
   where code_hash = h;
  return public.lotus_get_state(p_code);
end $$;

-- Undo the last Rebuild (within 15 minutes). Restores last week's items and marks.
create function public.lotus_undo_rebuild(p_code text, p_by text, p_device text, p_pin text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code); r public.lotus_stores; e text; pm jsonb;
begin
  select * into r from public.lotus_stores where code_hash = h;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  e := public.lotus_pin_check(h, p_pin);
  if e is not null then return jsonb_build_object('error', e); end if;
  select * into r from public.lotus_stores where code_hash = h for update;
  if r.prev_week is null or coalesce((r.meta ->> 'rebuiltAt')::bigint, 0) < public.lotus_now_ms() - 15 * 60 * 1000 then
    return jsonb_build_object('error', 'UNDO_EXPIRED');
  end if;
  pm := coalesce(r.prev_week -> 'meta', '{}'::jsonb);
  if r.prev_week ->> 'historyId' is not null then
    delete from public.lotus_history where id = (r.prev_week ->> 'historyId')::bigint and code_hash = h;
  end if;
  update public.lotus_stores
     set draft = coalesce(r.prev_week -> 'draft', '{}'::jsonb),
         -- new week number so every phone reloads; keep the old week's sent/done info
         meta = pm || jsonb_build_object('week', coalesce((r.meta ->> 'week')::integer, 0) + 1,
                                         'undoneAt', public.lotus_now_ms(), 'undoneBy', left(coalesce(p_by, ''), 40),
                                         'undoneDev', left(coalesce(p_device, ''), 40)),
         last_order = r.prev_week -> 'lastOrder',
         prev_week = null, updated_at = now()
   where code_hash = h;
  return public.lotus_get_state(p_code);
end $$;

-- ---------------------------------------------------------------------
-- Order history (newest first) for the History screen.
-- ---------------------------------------------------------------------
create function public.lotus_get_history(p_code text, p_limit integer default 26)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code);
begin
  if not exists (select 1 from public.lotus_stores where code_hash = h) then raise exception 'STORE_NOT_FOUND'; end if;
  return coalesce((select jsonb_agg(x.data order by x.id desc) from (
    select id, data from public.lotus_history where code_hash = h order by id desc limit least(greatest(coalesce(p_limit, 26), 1), 104)
  ) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- Owner PIN: set, change or remove (p_new = '' removes). 4–8 digits.
-- ---------------------------------------------------------------------
create function public.lotus_set_pin(p_code text, p_old text, p_new text)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code); e text;
begin
  if not exists (select 1 from public.lotus_stores where code_hash = h) then raise exception 'STORE_NOT_FOUND'; end if;
  if coalesce(p_new, '') <> '' and p_new !~ '^[0-9]{4,8}$' then return jsonb_build_object('error', 'PIN_FORMAT'); end if;
  e := public.lotus_pin_check(h, p_old);
  if e is not null then return jsonb_build_object('error', e); end if;
  update public.lotus_stores
     set pin_hash = case when coalesce(p_new, '') = '' then null else public.lotus_hash('pin:' || p_new) end,
         pin_fails = 0, pin_locked_until = null
   where code_hash = h;
  return jsonb_build_object('ok', true, 'hasPin', coalesce(p_new, '') <> '');
end $$;

create function public.lotus_verify_pin(p_code text, p_pin text)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code); e text;
begin
  if not exists (select 1 from public.lotus_stores where code_hash = h) then raise exception 'STORE_NOT_FOUND'; end if;
  e := public.lotus_pin_check(h, p_pin);
  if e is not null then return jsonb_build_object('error', e); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Create a store (Settings → Create store). true = created, false = already exists.
-- ---------------------------------------------------------------------
create function public.lotus_create_store(p_code text)
returns boolean language plpgsql security definer
set search_path = public, pg_catalog
as $$
begin
  if length(trim(coalesce(p_code, ''))) < 8 then raise exception 'Store code must be at least 8 characters'; end if;
  if exists (select 1 from public.lotus_stores where code_hash = public.lotus_hash(p_code)) then return false; end if;
  if (select count(*) from public.lotus_stores) >= 20 then raise exception 'Store limit reached'; end if;
  insert into public.lotus_stores (code_hash) values (public.lotus_hash(p_code));
  return true;
end $$;

-- Keep-awake ping (called by the GitHub Action every few days so the free project never pauses).
create function public.lotus_ping()
returns boolean language sql stable security definer
set search_path = public, pg_catalog
as $$ select exists (select 1 from public.lotus_stores) or true $$;

-- Admin only (run here in the SQL editor): change the store code; data is kept.
create function public.lotus_change_code(p_old text, p_new text)
returns text language plpgsql security definer
set search_path = public, pg_catalog
as $$
begin
  if length(trim(coalesce(p_new, ''))) < 8 then raise exception 'New code must be at least 8 characters'; end if;
  update public.lotus_stores set code_hash = public.lotus_hash(p_new) where code_hash = public.lotus_hash(p_old);
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  return 'Code changed.';
end $$;

-- Admin only: forgot the owner PIN? Run:  select public.lotus_reset_pin('your-store-code');
create function public.lotus_reset_pin(p_code text)
returns text language plpgsql security definer
set search_path = public, pg_catalog
as $$
begin
  update public.lotus_stores set pin_hash = null, pin_fails = 0, pin_locked_until = null where code_hash = public.lotus_hash(p_code);
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  return 'PIN removed.';
end $$;

-- ---------------------------------------------------------------------
-- Permissions: lock everything, then open only the app's functions.
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'lotus\_%' loop
    execute 'revoke all on function ' || f.sig || ' from public, anon, authenticated';
  end loop;
end $$;

grant execute on function public.lotus_get_state(text)                                         to anon, authenticated;
grant execute on function public.lotus_patch_draft(text, jsonb, integer, text)                 to anon, authenticated;
grant execute on function public.lotus_save_catalog(text, jsonb, integer, text, text)          to anon, authenticated;
grant execute on function public.lotus_mark_ready(text, integer, text, text, integer, jsonb)   to anon, authenticated;
grant execute on function public.lotus_rebuild(text, text, text, jsonb, jsonb, text)           to anon, authenticated;
grant execute on function public.lotus_undo_rebuild(text, text, text, text)                    to anon, authenticated;
grant execute on function public.lotus_get_history(text, integer)                              to anon, authenticated;
grant execute on function public.lotus_set_pin(text, text, text)                               to anon, authenticated;
grant execute on function public.lotus_verify_pin(text, text)                                  to anon, authenticated;
grant execute on function public.lotus_create_store(text)                                      to anon, authenticated;
grant execute on function public.lotus_ping()                                                  to anon, authenticated;

-- Done. Open the app → ⚙︎ Settings → paste your Project URL + key → Create store.
