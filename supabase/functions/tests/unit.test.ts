// Unit tests (no network): webhook signature and payload validation.
// Run: npx deno test --allow-env supabase/functions/tests/unit.test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { MAX_CLOCK_SKEW_SECONDS, sign, verifySignature } from "../_shared/signature.ts";
import { parseBillingEvent, parseInvite } from "../_shared/validation.ts";

const SECRET = "test-secret";
const BODY = '{"hello":"world"}';
const NOW = 1_800_000_000;

Deno.test("signature: valid signature is accepted", async () => {
  const sig = await sign(SECRET, String(NOW), BODY);
  assertEquals(await verifySignature(SECRET, String(NOW), sig, BODY, NOW), "OK");
});

Deno.test("signature: uppercase hex is accepted", async () => {
  const sig = (await sign(SECRET, String(NOW), BODY)).toUpperCase();
  assertEquals(await verifySignature(SECRET, String(NOW), sig, BODY, NOW), "OK");
});

Deno.test("signature: tampered body is rejected", async () => {
  const sig = await sign(SECRET, String(NOW), BODY);
  assertEquals(await verifySignature(SECRET, String(NOW), sig, '{"hello":"evil"}', NOW), "INVALID");
});

Deno.test("signature: wrong secret is rejected", async () => {
  const sig = await sign("other-secret", String(NOW), BODY);
  assertEquals(await verifySignature(SECRET, String(NOW), sig, BODY, NOW), "INVALID");
});

Deno.test("signature: timestamp is part of the signature", async () => {
  const sig = await sign(SECRET, String(NOW), BODY);
  assertEquals(await verifySignature(SECRET, String(NOW + 1), sig, BODY, NOW), "INVALID");
});

Deno.test("signature: stale or future timestamps are rejected", async () => {
  const old = String(NOW - MAX_CLOCK_SKEW_SECONDS - 1);
  assertEquals(await verifySignature(SECRET, old, await sign(SECRET, old, BODY), BODY, NOW), "STALE");
  const future = String(NOW + MAX_CLOCK_SKEW_SECONDS + 1);
  assertEquals(await verifySignature(SECRET, future, await sign(SECRET, future, BODY), BODY, NOW), "STALE");
  assertEquals(await verifySignature(SECRET, "abc", "00", BODY, NOW), "STALE");
});

Deno.test("signature: missing headers are rejected", async () => {
  assertEquals(await verifySignature(SECRET, null, "x", BODY, NOW), "MISSING");
  assertEquals(await verifySignature(SECRET, String(NOW), null, BODY, NOW), "MISSING");
});

const BID = "0a207c2c-cb81-48e1-a70e-ff7ab6e74493";

Deno.test("validation: invite payload", () => {
  const ok = parseInvite({ business_id: BID, email: "  Awa@Example.SN ", role_code: "CASHIER" });
  assertEquals(ok.ok && ok.value.email, "awa@example.sn");
  assertEquals(parseInvite(null).ok, false);
  assertEquals(parseInvite({ business_id: "x", email: "a@b.c", role_code: "CASHIER" }).ok, false);
  assertEquals(parseInvite({ business_id: BID, email: "not-an-email", role_code: "CASHIER" }).ok, false);
  assertEquals(parseInvite({ business_id: BID, email: "a@b.c", role_code: "cashier" }).ok, false);
  assertEquals(parseInvite({ business_id: BID, email: "a@b.c", role_code: "CASHIER", redirect_to: "javascript:x" }).ok, false);
});

Deno.test("validation: billing event payload", () => {
  const base = { provider: "wave", event_id: "evt-1", business_id: BID, plan_code: "PRO", months: 1, amount: 10000 };
  assertEquals(parseBillingEvent(base).ok, true);
  assertEquals(parseBillingEvent({ ...base, months: 0 }).ok, false);
  assertEquals(parseBillingEvent({ ...base, months: 1.5 }).ok, false);
  assertEquals(parseBillingEvent({ ...base, amount: -1 }).ok, false);
  assertEquals(parseBillingEvent({ ...base, amount: 10.5 }).ok, false);
  assertEquals(parseBillingEvent({ ...base, plan_code: "pro" }).ok, false);
  assertEquals(parseBillingEvent({ ...base, provider: "Wave Money" }).ok, false);
  assertEquals(parseBillingEvent({ ...base, event_id: "" }).ok, false);
});
