// HTTP helpers shared by all Edge Functions: CORS, JSON responses and the
// mapping of PostgreSQL / RPC errors (docs/business-rules.md §13) to HTTP codes.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function errorResponse(status: number, code: string, detail?: string): Response {
  return json(status, { error: code, ...(detail ? { detail } : {}) });
}

export interface DbError {
  code?: string;
  message?: string;
  details?: string | null;
}

// SQLSTATE -> HTTP. The stable machine code is the error message.
export function fromDbError(error: DbError): Response {
  const code = error.code ?? "";
  const message = error.message ?? "UNKNOWN_ERROR";
  const detail = error.details ?? undefined;
  if (code === "42501") return errorResponse(403, message, detail);
  if (code === "P0002") return errorResponse(404, message, detail);
  if (code === "P0001" || code === "23505") return errorResponse(409, message, detail);
  if (code === "22023" || code === "23514" || code === "22P02") return errorResponse(400, message, detail);
  // Unexpected: do not leak internals.
  console.error("unexpected database error", error);
  return errorResponse(500, "INTERNAL_ERROR");
}

export async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : null;
  } catch {
    return null;
  }
}
