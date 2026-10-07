// Supabase clients for Edge Functions.
// - userClient: acts AS the caller (their JWT) -> RLS and RPC permission checks apply.
// - adminClient: service_role -> bypasses RLS. Use only for operations that
//   genuinely need it (Auth admin API, platform RPCs), never to skip checks.
// Keys come from the Edge runtime environment; never hardcode them.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

const options = { auth: { persistSession: false, autoRefreshToken: false } };

export function userClient(authorization: string): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    ...options,
    global: { headers: { Authorization: authorization } },
  });
}

export function adminClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), options);
}
