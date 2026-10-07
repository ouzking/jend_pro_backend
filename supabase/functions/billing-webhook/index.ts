// POST /functions/v1/billing-webhook
// Provider-agnostic subscription payment confirmation (verify_jwt = false:
// called by the payment provider / billing back-office, authenticated by
// HMAC signature instead of a user JWT).
//
// Headers: x-jendpro-timestamp (unix s), x-jendpro-signature = hex(HMAC-SHA256(secret, `${ts}.${body}`))
// Body:    { provider, event_id, business_id, plan_code, months, amount }
//
// Processing is idempotent per (provider, event_id) and the database checks
// that the amount covers the plan price. Provider-specific adapters (Wave,
// Orange Money) translate their native webhook into this payload.
import { adminClient } from "../_shared/clients.ts";
import { corsHeaders, errorResponse, fromDbError, json } from "../_shared/http.ts";
import { verifySignature } from "../_shared/signature.ts";
import { parseBillingEvent } from "../_shared/validation.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return errorResponse(405, "METHOD_NOT_ALLOWED");

  const secret = Deno.env.get("BILLING_WEBHOOK_SECRET");
  if (!secret) {
    console.error("BILLING_WEBHOOK_SECRET is not configured");
    return errorResponse(500, "NOT_CONFIGURED");
  }

  const rawBody = await req.text();
  const check = await verifySignature(
    secret,
    req.headers.get("x-jendpro-timestamp"),
    req.headers.get("x-jendpro-signature"),
    rawBody,
  );
  if (check !== "OK") return errorResponse(401, "INVALID_SIGNATURE", check);

  let body: Record<string, unknown> | null = null;
  try {
    body = JSON.parse(rawBody);
  } catch {
    body = null;
  }
  const event = parseBillingEvent(body);
  if (!event.ok) return errorResponse(400, "INVALID_INPUT", event.errors.join("; "));

  const { provider, event_id, business_id, plan_code, months, amount } = event.value;
  const { data, error } = await adminClient().rpc("platform_activate_subscription", {
    p_provider: provider,
    p_event_id: event_id,
    p_business_id: business_id,
    p_plan_code: plan_code,
    p_months: months,
    p_amount: amount,
  });
  if (error) return fromDbError(error);

  // No personal or payment data in logs: ids only.
  console.log(`billing event ${provider}:${event_id} processed`, JSON.stringify(data));
  return json(200, data);
});
