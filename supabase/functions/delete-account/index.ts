// Deletes the caller's account (App Store requirement; plan §3.1).
// POST with the user's JWT. Owned trips go to another member or are deleted,
// shared records keep existing with the actor anonymised, then the auth user
// and personal data (profile, memberships, interests) are removed.

import { createClient } from "@supabase/supabase-js";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
  if (!token) return json({ error: "UNAUTHENTICATED" }, 401);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    db: { schema: "app" },
    auth: { persistSession: false },
  });
  const { data, error } = await admin.auth.getUser(token);
  const userId = data.user?.id;
  if (error || !userId) return json({ error: "UNAUTHENTICATED" }, 401);

  const prep = await admin.rpc("prepare_account_deletion", { p_user_id: userId });
  if (prep.error) {
    console.log(JSON.stringify({ fn: "delete-account", status: "prepare_failed" }));
    return json({ error: "DELETE_FAILED" }, 500);
  }
  // The auth user can't be deleted in the same transaction as the preparation.
  // Preparation is idempotent, so retry here and, if it still fails, tell the app
  // the account is only partly deleted and a retry will finish it.
  let removed = await admin.auth.admin.deleteUser(userId);
  for (let attempt = 1; removed.error && attempt < 3; attempt++) {
    await new Promise((r) => setTimeout(r, 500 * attempt));
    removed = await admin.auth.admin.deleteUser(userId);
  }
  if (removed.error) {
    console.log(JSON.stringify({ fn: "delete-account", status: "delete_failed" }));
    return json({ error: "DELETE_INCOMPLETE" }, 500);
  }
  console.log(JSON.stringify({ fn: "delete-account", status: "deleted", ...prep.data }));
  return json({ status: "deleted", ...prep.data });
});
