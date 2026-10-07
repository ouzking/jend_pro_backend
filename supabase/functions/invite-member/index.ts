// POST /functions/v1/invite-member
// Invites a person into a business, creating their account if needed.
// Body: { business_id, email, role_code, redirect_to? }   Auth: caller JWT (verify_jwt = true)
//
// Security model:
//  1. The caller must hold members.manage in the business (checked BEFORE any
//     account is created, so the endpoint cannot be abused to send e-mails).
//  2. The membership itself is created by the invite_member RPC executed AS
//     THE CALLER: the database enforces every rule (role hierarchy, limits…).
//  3. service_role is used only for the Auth admin API (account creation).
import { adminClient, userClient } from "../_shared/clients.ts";
import { corsHeaders, errorResponse, fromDbError, json, readJson } from "../_shared/http.ts";
import { parseInvite } from "../_shared/validation.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return errorResponse(405, "METHOD_NOT_ALLOWED");

  const authorization = req.headers.get("Authorization");
  if (!authorization) return errorResponse(401, "NOT_AUTHENTICATED");

  const input = parseInvite(await readJson(req));
  if (!input.ok) return errorResponse(400, "INVALID_INPUT", input.errors.join("; "));
  const { business_id, email, role_code, redirect_to } = input.value;

  const caller = userClient(authorization);
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData.user) return errorResponse(401, "NOT_AUTHENTICATED");

  const { data: permissions, error: permError } = await caller.rpc("get_my_permissions", { p_business_id: business_id });
  if (permError) return fromDbError(permError);
  if (!(permissions as string[]).includes("members.manage")) {
    return errorResponse(403, "PERMISSION_DENIED", "members.manage");
  }

  const invite = () =>
    caller.rpc("invite_member", { p_business_id: business_id, p_email: email, p_role_code: role_code });

  let { data: memberId, error } = await invite();
  let accountCreated = false;

  if (error?.message === "USER_NOT_FOUND") {
    const { error: adminError } = await adminClient().auth.admin.inviteUserByEmail(email, {
      redirectTo: redirect_to ?? Deno.env.get("SITE_URL") ?? undefined,
      data: { invited_to_business: business_id },
    });
    if (adminError) {
      console.error("inviteUserByEmail failed", adminError.message);
      return errorResponse(502, "AUTH_INVITE_FAILED");
    }
    accountCreated = true;
    ({ data: memberId, error } = await invite());
  }

  if (error) return fromDbError(error);
  return json(200, { member_id: memberId, account_created: accountCreated });
});
