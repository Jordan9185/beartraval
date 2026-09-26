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

  // 圖片是私有 Storage 物件，不會隨 auth.users 的外鍵 cascade；先刪除該帳號目錄。
  const imageBucket = admin.storage.from("inbox-images");
  const paths: string[] = [];
  for (let offset = 0; ; offset += 100) {
    const { data: folders, error: listError } = await imageBucket.list(userId, { limit: 100, offset });
    if (listError) return json({ error: "DELETE_FAILED" }, 500);
    for (const folder of folders ?? []) {
      if (!folder.name) continue;
      const prefix = `${userId}/${folder.name}`;
      for (let fileOffset = 0; ; fileOffset += 100) {
        const { data: files, error: fileError } = await imageBucket.list(prefix, { limit: 100, offset: fileOffset });
        if (fileError) return json({ error: "DELETE_FAILED" }, 500);
        paths.push(...(files ?? []).filter((file) => file.name && file.id).map((file) => `${prefix}/${file.name}`));
        if ((files ?? []).length < 100) break;
      }
    }
    if ((folders ?? []).length < 100) break;
  }
  for (let offset = 0; offset < paths.length; offset += 100) {
    const { error: removeError } = await imageBucket.remove(paths.slice(offset, offset + 100));
    if (removeError) return json({ error: "DELETE_FAILED" }, 500);
  }

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
