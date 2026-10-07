// Webhook signature: hex(HMAC-SHA256(secret, `${timestamp}.${rawBody}`)).
// Headers: x-jendpro-timestamp (unix seconds), x-jendpro-signature (hex).
// The timestamp is signed and must be recent, so a captured request cannot be
// replayed later (and event ids make processing idempotent anyway).

export const MAX_CLOCK_SKEW_SECONDS = 300;

const encoder = new TextEncoder();

export async function sign(secret: string, timestamp: string, rawBody: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${rawBody}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type SignatureCheck = "OK" | "MISSING" | "STALE" | "INVALID";

export async function verifySignature(
  secret: string,
  timestamp: string | null,
  signature: string | null,
  rawBody: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<SignatureCheck> {
  if (!timestamp || !signature) return "MISSING";
  const ts = Number(timestamp);
  if (!Number.isInteger(ts) || Math.abs(nowSeconds - ts) > MAX_CLOCK_SKEW_SECONDS) return "STALE";
  const expected = await sign(secret, timestamp, rawBody);
  return timingSafeEqual(expected, signature.toLowerCase()) ? "OK" : "INVALID";
}
