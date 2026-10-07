// Integration tests against locally served Edge Functions.
// Run with: bash scripts/test-functions.sh   (starts `supabase functions serve`,
// exports local keys from `supabase status`, runs these tests).
// Required env: API_URL, ANON_KEY, SERVICE_ROLE_KEY, BILLING_WEBHOOK_SECRET.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { sign } from "../_shared/signature.ts";

const API_URL = Deno.env.get("API_URL")!;
const ANON_KEY = Deno.env.get("ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("BILLING_WEBHOOK_SECRET")!;
const FN = `${API_URL}/functions/v1`;
const RUN = crypto.randomUUID().slice(0, 8);
const opts = { auth: { persistSession: false, autoRefreshToken: false } };

const admin = createClient(API_URL, SERVICE_ROLE_KEY, opts);

async function newUser(name: string): Promise<{ client: SupabaseClient; token: string; email: string }> {
  const email = `${name}-${RUN}@test.local`;
  const password = "test-password-123";
  const { error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  const client = createClient(API_URL, ANON_KEY, opts);
  const { data, error: e2 } = await client.auth.signInWithPassword({ email, password });
  if (e2) throw e2;
  return { client, token: data.session!.access_token, email };
}

async function call(fn: string, token: string | null, body: unknown, extraHeaders: Record<string, string> = {}) {
  const res = await fetch(`${FN}/${fn}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: ANON_KEY,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...extraHeaders,
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function userExists(email: string): Promise<boolean> {
  const { data } = await admin.auth.admin.listUsers({ perPage: 1000 });
  return data.users.some((u) => u.email === email);
}

// ---------------------------------------------------------------------------
// Fixture: owner of business A, a cashier of A, owner of business B.
// ---------------------------------------------------------------------------
const owner = await newUser("owner");
const cashier = await newUser("cashier");
const ownerB = await newUser("ownerb");
const { data: businessA } = await owner.client.rpc("create_business", { p_name: `Boutique ${RUN}` });
const { data: businessB } = await ownerB.client.rpc("create_business", { p_name: `Autre ${RUN}` });
await owner.client.rpc("invite_member", { p_business_id: businessA, p_email: cashier.email, p_role_code: "CASHIER" });
await cashier.client.rpc("accept_invitation", { p_business_id: businessA });

// ---------------------------------------------------------------------------
// invite-member
// ---------------------------------------------------------------------------
Deno.test("invite-member: rejects anonymous calls", async () => {
  const r = await call("invite-member", null, { business_id: businessA, email: "x@y.sn", role_code: "CASHIER" });
  assertEquals(r.status, 401);
});

Deno.test("invite-member: rejects malformed input", async () => {
  const r = await call("invite-member", owner.token, { business_id: "nope", email: "bad", role_code: "x" });
  assertEquals(r.status, 400);
  assertEquals(r.body.error, "INVALID_INPUT");
});

Deno.test("invite-member: a cashier cannot invite, and no account is created", async () => {
  const email = `victim-${RUN}@test.local`;
  const r = await call("invite-member", cashier.token, { business_id: businessA, email, role_code: "CASHIER" });
  assertEquals(r.status, 403);
  assertEquals(r.body.error, "PERMISSION_DENIED");
  assertEquals(await userExists(email), false);
});

Deno.test("invite-member: cannot invite into another business", async () => {
  const r = await call("invite-member", owner.token, { business_id: businessB, email: `z-${RUN}@test.local`, role_code: "CASHIER" });
  assertEquals(r.status, 403);
});

Deno.test("invite-member: creates the account of a new person and invites them", async () => {
  const email = `newbie-${RUN}@test.local`;
  const r = await call("invite-member", owner.token, { business_id: businessA, email, role_code: "STOCK_MANAGER" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(r.body.account_created, true);
  assert(await userExists(email));
  const { data } = await admin.from("business_members").select("status").eq("id", r.body.member_id).single();
  assertEquals(data!.status, "INVITED");
});

Deno.test("invite-member: invites an existing user without creating an account", async () => {
  const existing = await newUser("existing");
  const r = await call("invite-member", owner.token, { business_id: businessA, email: existing.email, role_code: "CASHIER" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(r.body.account_created, false);
  const again = await call("invite-member", owner.token, { business_id: businessA, email: existing.email, role_code: "CASHIER" });
  assertEquals(again.status, 409);
  assertEquals(again.body.error, "ALREADY_MEMBER");
});

// ---------------------------------------------------------------------------
// billing-webhook
// ---------------------------------------------------------------------------
async function webhook(payload: unknown, opts: { secret?: string; ts?: number; omit?: boolean } = {}) {
  const raw = JSON.stringify(payload);
  const ts = String(opts.ts ?? Math.floor(Date.now() / 1000));
  const sig = await sign(opts.secret ?? SECRET, ts, raw);
  return call("billing-webhook", null, raw, opts.omit ? {} : { "x-jendpro-timestamp": ts, "x-jendpro-signature": sig });
}

const event = (id: string, extra: Record<string, unknown> = {}) => ({
  provider: "wave", event_id: `${id}-${RUN}`, business_id: businessA, plan_code: "PRO", months: 1, amount: 10000, ...extra,
});

Deno.test("billing-webhook: rejects unsigned, mis-signed and stale requests", async () => {
  assertEquals((await webhook(event("e0"), { omit: true })).body.detail, "MISSING");
  const bad = await webhook(event("e0"), { secret: "wrong" });
  assertEquals([bad.status, bad.body.detail], [401, "INVALID"]);
  const stale = await webhook(event("e0"), { ts: Math.floor(Date.now() / 1000) - 3600 });
  assertEquals([stale.status, stale.body.detail], [401, "STALE"]);
});

Deno.test("billing-webhook: rejects invalid payloads", async () => {
  const r = await webhook(event("e1", { months: 0 }));
  assertEquals([r.status, r.body.error], [400, "INVALID_INPUT"]);
});

Deno.test("billing-webhook: activates the subscription, idempotently", async () => {
  const first = await webhook(event("e2"));
  assertEquals(first.status, 200, JSON.stringify(first.body));
  assertEquals(first.body.duplicate, false);
  const { data: sub } = await admin.from("subscriptions").select("status, current_period_end")
    .eq("id", first.body.subscription_id).single();
  assertEquals(sub!.status, "ACTIVE");

  const replay = await webhook(event("e2"));
  assertEquals([replay.status, replay.body.duplicate], [200, true]);
  const { data: after } = await admin.from("subscriptions").select("current_period_end")
    .eq("id", first.body.subscription_id).single();
  assertEquals(after!.current_period_end, sub!.current_period_end);
});

Deno.test("billing-webhook: refuses an amount below the plan price", async () => {
  const r = await webhook(event("e3", { amount: 100 }));
  assertEquals([r.status, r.body.error], [409, "AMOUNT_MISMATCH"]);
});

Deno.test("billing-webhook: only POST is accepted", async () => {
  const res = await fetch(`${FN}/billing-webhook`, { method: "GET", headers: { apikey: ANON_KEY } });
  await res.body?.cancel();
  assertEquals(res.status, 405);
});
