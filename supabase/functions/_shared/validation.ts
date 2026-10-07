// Input validation for Edge Function payloads. Returns a typed value or a list
// of field errors. The database re-validates everything; this layer only
// rejects malformed requests early with clear messages.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const ROLE_CODE = /^[A-Z][A-Z_]{1,49}$/;
const PLAN_CODE = /^[A-Z][A-Z_]{1,29}$/;
const PROVIDER = /^[a-z][a-z0-9_]{0,39}$/;

export type Result<T> = { ok: true; value: T } | { ok: false; errors: string[] };

export interface InviteInput {
  business_id: string;
  email: string;
  role_code: string;
  redirect_to?: string;
}

export function parseInvite(body: Record<string, unknown> | null): Result<InviteInput> {
  if (!body) return { ok: false, errors: ["body must be a JSON object"] };
  const errors: string[] = [];
  const { business_id, email, role_code, redirect_to } = body;
  if (typeof business_id !== "string" || !UUID.test(business_id)) errors.push("business_id must be a UUID");
  if (typeof email !== "string" || email.length > 254 || !EMAIL.test(email.trim())) errors.push("email is invalid");
  if (typeof role_code !== "string" || !ROLE_CODE.test(role_code)) errors.push("role_code is invalid");
  if (redirect_to !== undefined && (typeof redirect_to !== "string" || !/^https?:\/\//.test(redirect_to))) {
    errors.push("redirect_to must be an http(s) URL");
  }
  if (errors.length) return { ok: false, errors };
  return {
    ok: true,
    value: {
      business_id: business_id as string,
      email: (email as string).trim().toLowerCase(),
      role_code: role_code as string,
      redirect_to: redirect_to as string | undefined,
    },
  };
}

export interface BillingEvent {
  provider: string;
  event_id: string;
  business_id: string;
  plan_code: string;
  months: number;
  amount: number;
}

export function parseBillingEvent(body: Record<string, unknown> | null): Result<BillingEvent> {
  if (!body) return { ok: false, errors: ["body must be a JSON object"] };
  const errors: string[] = [];
  const { provider, event_id, business_id, plan_code, months, amount } = body;
  if (typeof provider !== "string" || !PROVIDER.test(provider)) errors.push("provider is invalid");
  if (typeof event_id !== "string" || event_id.length < 1 || event_id.length > 200) errors.push("event_id is invalid");
  if (typeof business_id !== "string" || !UUID.test(business_id)) errors.push("business_id must be a UUID");
  if (typeof plan_code !== "string" || !PLAN_CODE.test(plan_code)) errors.push("plan_code is invalid");
  if (!Number.isInteger(months) || (months as number) < 1 || (months as number) > 36) errors.push("months must be 1..36");
  if (!Number.isSafeInteger(amount) || (amount as number) < 0) errors.push("amount must be a non-negative integer (XOF)");
  if (errors.length) return { ok: false, errors };
  return { ok: true, value: body as unknown as BillingEvent };
}
