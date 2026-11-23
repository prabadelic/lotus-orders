/*
 * LOTUS ORDERS — sync configuration.
 *
 * Leave both values empty to run in "this phone only" mode (no sharing).
 * To share one live list between phones, create a free Supabase project,
 * run supabase/setup.sql, then paste your Project URL and anon/publishable key here.
 * (Supabase dashboard → Project Settings → API.)
 *
 * The anon/publishable key is designed to be public. The data is protected by
 * your STORE CODE, which is never stored in this file — each phone enters it once
 * (or opens the invite link from Settings).
 */
window.LOTUS_CONFIG = {
  supabaseUrl: "https://ycmwdbejeubukugnrpgw.supabase.co",      // e.g. "https://abcdefghijkl.supabase.co"
  supabaseAnonKey: "sb_publishable_zb5T2uZUmGgqXP9SclhCLg_rN-d1Fkd"   // e.g. "sb_publishable_..." or the legacy "eyJhbGci..." anon key
};
