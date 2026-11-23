-- =====================================================================
-- LOTUS ORDERS v1.1 — Supabase setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run. Safe to re-run.
-- Then create your store from the app: ⚙︎ Settings → Create store.
-- =====================================================================
-- Security model:
--   * Nobody needs an account. Each store is protected by a STORE CODE (a passphrase).
--   * The table is locked (RLS on, no policies, no grants): the public anon key cannot
--     read or write it directly.
--   * Phones talk only to the functions below, which require the store code.
--     Only a SHA-256 hash of the code is stored.
--   * Pick a long code (e.g. 3–4 random words: "mango-river-tulip-42"). Anyone who
--     has the code can edit the list, so share it only with your team.
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
alter table public.lotus_stores enable row level security;
revoke all on table public.lotus_stores from anon, authenticated;

-- Hash helper (built-in sha256, no extension needed).
create or replace function public.lotus_hash(p_code text)
returns text language sql immutable
set search_path = public, pg_catalog
as $$ select encode(sha256(convert_to(trim(coalesce(p_code, '')), 'UTF8')), 'hex') $$;

-- ---------------------------------------------------------------------
-- Read everything for one store.
-- ---------------------------------------------------------------------
create or replace function public.lotus_get_state(p_code text)
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
    'serverTime', now()
  );
end $$;

-- ---------------------------------------------------------------------
-- Merge per-product changes into this week's shared order.
-- Entry: {n: on order, q: quantity, d: done, t: timestamp ms, b: name, v: device}.
-- Newest timestamp wins per product, so people editing different products
-- at the same moment never overwrite each other. A phone still on last
-- week's list gets WEEK_CHANGED and reloads.
-- ---------------------------------------------------------------------
drop function if exists public.lotus_patch_draft(text, jsonb, text);
create or replace function public.lotus_patch_draft(p_code text, p_patch jsonb, p_week integer, p_by text default '')
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
  h   text := public.lotus_hash(p_code);
  cur jsonb;
  m   jsonb;
  k   text;
  v   jsonb;
  n   boolean;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'BAD_PATCH'; end if;
  if octet_length(p_patch::text) > 100000 then raise exception 'PATCH_TOO_LARGE'; end if;

  select draft, meta into cur, m from public.lotus_stores where code_hash = h for update;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  if coalesce((m ->> 'week')::integer, 0) <> coalesce(p_week, -1) then raise exception 'WEEK_CHANGED'; end if;

  for k, v in select key, value from jsonb_each(p_patch) loop
    continue when jsonb_typeof(v) <> 'object' or length(k) > 60;
    if cur ? k and coalesce((cur -> k ->> 't')::numeric, 0) > coalesce((v ->> 't')::numeric, 0) then
      continue; -- server copy is newer
    end if;
    n := coalesce((v ->> 'n')::boolean, false);
    cur := cur || jsonb_build_object(k, jsonb_build_object(
      'n', n,
      'q', left(coalesce(v ->> 'q', ''), 20),
      'd', n and coalesce((v ->> 'd')::boolean, false),
      't', coalesce((v ->> 't')::numeric, 0),
      'b', left(coalesce(nullif(v ->> 'b', ''), p_by, ''), 40),
      'v', left(coalesce(v ->> 'v', ''), 40)
    ));
  end loop;

  update public.lotus_stores set draft = cur, updated_at = now() where code_hash = h;
  return cur;
end $$;

-- ---------------------------------------------------------------------
-- Save the product list. p_base_version must match the current version,
-- otherwise CATALOG_CONFLICT (someone else saved first) and the app asks
-- which version to keep.
-- ---------------------------------------------------------------------
create or replace function public.lotus_save_catalog(p_code text, p_catalog jsonb, p_base_version integer, p_by text default '')
returns integer language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
  h   text := public.lotus_hash(p_code);
  ver integer;
begin
  if p_catalog is null or jsonb_typeof(p_catalog -> 'items') <> 'array' then raise exception 'BAD_CATALOG'; end if;
  if octet_length(p_catalog::text) > 200000 then raise exception 'CATALOG_TOO_LARGE'; end if;

  select catalog_version into ver from public.lotus_stores where code_hash = h for update;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  if ver <> coalesce(p_base_version, -1) then raise exception 'CATALOG_CONFLICT'; end if;

  update public.lotus_stores
     set catalog = p_catalog,
         catalog_version = ver + 1,
         catalog_updated_at = now(),
         catalog_updated_by = left(coalesce(p_by, ''), 40),
         updated_at = now()
   where code_hash = h;
  return ver + 1;
end $$;

-- ---------------------------------------------------------------------
-- Send Order: mark this week's order as ready (alerts the other phones)
-- and remember its quantities for the "Last: 5" hints.
-- ---------------------------------------------------------------------
drop function if exists public.lotus_set_last_order(text, jsonb, text);
create or replace function public.lotus_mark_ready(p_code text, p_week integer, p_by text, p_device text, p_count integer, p_last jsonb)
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
     set meta = m || jsonb_build_object(
           'readyAt', floor(extract(epoch from clock_timestamp()) * 1000),
           'readyBy', left(coalesce(p_by, ''), 40),
           'readyDev', left(coalesce(p_device, ''), 40),
           'readyCount', greatest(0, least(coalesce(p_count, 0), 10000))),
         last_order = coalesce(p_last, last_order),
         updated_at = now()
   where code_hash = h;
  return public.lotus_get_state(p_code);
end $$;

-- ---------------------------------------------------------------------
-- Rebuild: start a new, blank week for everyone. The product list stays;
-- the finished week's quantities are kept as the "last order".
-- ---------------------------------------------------------------------
create or replace function public.lotus_rebuild(p_code text, p_by text, p_device text, p_last jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare h text := public.lotus_hash(p_code); m jsonb;
begin
  if p_last is not null and (jsonb_typeof(p_last -> 'items') <> 'object' or octet_length(p_last::text) > 50000) then raise exception 'BAD_ORDER'; end if;
  select meta into m from public.lotus_stores where code_hash = h for update;
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  update public.lotus_stores
     set meta = jsonb_build_object(
           'week', coalesce((m ->> 'week')::integer, 0) + 1,
           'rebuiltAt', floor(extract(epoch from clock_timestamp()) * 1000),
           'rebuiltBy', left(coalesce(p_by, ''), 40),
           'rebuiltDev', left(coalesce(p_device, ''), 40)),
         draft = '{}'::jsonb,
         last_order = coalesce(p_last, last_order),
         updated_at = now()
   where code_hash = h;
  return public.lotus_get_state(p_code);
end $$;

-- ---------------------------------------------------------------------
-- Create a store (called from the app's Settings → Create store).
-- Returns true if created, false if that code already exists.
-- Capped at 20 stores per project to stop abuse.
-- ---------------------------------------------------------------------
drop function if exists public.lotus_create_store(text);
create or replace function public.lotus_create_store(p_code text)
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

-- Admin only (run here in the SQL editor; not callable from the app).
-- Change the code later (everyone re-enters the new code; data is kept):
create or replace function public.lotus_change_code(p_old text, p_new text)
returns text language plpgsql security definer
set search_path = public, pg_catalog
as $$
begin
  if length(trim(coalesce(p_new, ''))) < 8 then raise exception 'New code must be at least 8 characters'; end if;
  update public.lotus_stores set code_hash = public.lotus_hash(p_new) where code_hash = public.lotus_hash(p_old);
  if not found then raise exception 'STORE_NOT_FOUND'; end if;
  return 'Code changed.';
end $$;

-- Permissions: the app (anon) may call only these functions.
revoke all on function public.lotus_hash(text)                                            from public, anon, authenticated;
revoke all on function public.lotus_get_state(text)                                       from public, anon, authenticated;
revoke all on function public.lotus_patch_draft(text, jsonb, integer, text)               from public, anon, authenticated;
revoke all on function public.lotus_save_catalog(text, jsonb, integer, text)              from public, anon, authenticated;
revoke all on function public.lotus_mark_ready(text, integer, text, text, integer, jsonb) from public, anon, authenticated;
revoke all on function public.lotus_rebuild(text, text, text, jsonb)                      from public, anon, authenticated;
revoke all on function public.lotus_create_store(text)                                    from public, anon, authenticated;
revoke all on function public.lotus_change_code(text, text)                               from public, anon, authenticated;

grant execute on function public.lotus_get_state(text)                                    to anon, authenticated;
grant execute on function public.lotus_patch_draft(text, jsonb, integer, text)            to anon, authenticated;
grant execute on function public.lotus_save_catalog(text, jsonb, integer, text)           to anon, authenticated;
grant execute on function public.lotus_mark_ready(text, integer, text, text, integer, jsonb) to anon, authenticated;
grant execute on function public.lotus_rebuild(text, text, text, jsonb)                   to anon, authenticated;
grant execute on function public.lotus_create_store(text)                                 to anon, authenticated;

-- Done. Now open the app → ⚙︎ Settings → paste your Project URL + key → Create store.
