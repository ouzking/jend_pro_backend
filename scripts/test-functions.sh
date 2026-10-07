#!/usr/bin/env bash
# Runs the Edge Function test suites against the local Supabase stack.
#   1. unit tests (no network)
#   2. serves the functions locally with supabase/functions/.env
#   3. integration tests (keys taken from `supabase status`, never hardcoded)
# Prerequisites: `npx supabase start` and supabase/functions/.env (see .env.example).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f supabase/functions/.env ]]; then
  echo "supabase/functions/.env is missing (copy supabase/functions/.env.example)" >&2
  exit 1
fi

echo "== unit tests"
npx --yes deno test --allow-env supabase/functions/tests/unit.test.ts

echo "== serving functions"
npx --yes supabase functions serve --env-file supabase/functions/.env > /tmp/jendpro-functions.log 2>&1 &
SERVE_PID=$!
trap 'kill $SERVE_PID 2>/dev/null || true' EXIT

# Local keys and URLs of this machine's stack.
eval "$(npx --yes supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"
export API_URL ANON_KEY SERVICE_ROLE_KEY
export BILLING_WEBHOOK_SECRET="$(grep -E '^BILLING_WEBHOOK_SECRET=' supabase/functions/.env | cut -d= -f2-)"

for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$API_URL/functions/v1/billing-webhook" || true)
  [[ "$code" == "200" ]] && break
  sleep 1
done

echo "== integration tests"
npx --yes deno test --allow-env --allow-net supabase/functions/tests/functions.test.ts
