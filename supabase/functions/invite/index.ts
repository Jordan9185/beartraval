// Read-only invite preview page (D4): trip name, dates, inviter and role only,
// never itinerary content. GET /functions/v1/invite?token=<token>
//
// The "open in app" button uses the beartravel:// scheme for now; switch to a
// Universal Link once the app has a domain with an apple-app-site-association.

import { createClient } from "@supabase/supabase-js";

const escape = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const page = (title: string, body: string) =>
  new Response(
    `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${escape(title)}</title>
<style>body{font:17px -apple-system,system-ui,sans-serif;max-width:28rem;margin:3rem auto;padding:0 1rem;color:#1c1c1e}
h1{font-size:1.5rem}.muted{color:#6e6e73}a.button{display:inline-block;margin-top:1.5rem;padding:.8rem 1.4rem;border-radius:.8rem;background:#0a84ff;color:#fff;text-decoration:none}
@media(prefers-color-scheme:dark){body{background:#000;color:#f2f2f7}.muted{color:#98989d}}</style></head>
<body>${body}</body></html>`,
    {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
      },
    },
  );

Deno.serve(async (req) => {
  const token = new URL(req.url).searchParams.get("token") ?? "";
  if (!/^[0-9a-f]{64}$/.test(token)) {
    return page("邀請無效", `<h1>邀請連結無效</h1><p class="muted">請向 Trip 擁有者索取新的邀請。</p>`);
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    db: { schema: "app" },
  });
  const { data, error } = await admin.rpc("invite_preview", { p_token: token });
  if (error || !data || data.status === "invalid") {
    return page("邀請無效", `<h1>邀請連結無效</h1><p class="muted">請向 Trip 擁有者索取新的邀請。</p>`);
  }
  if (data.status !== "valid") {
    const reason = data.status === "revoked" ? "已被撤銷" : "已過期";
    return page("邀請失效", `<h1>這個邀請${reason}</h1><p class="muted">請向 Trip 擁有者索取新的邀請。</p>`);
  }

  const role = data.role === "editor" ? "可編輯" : "僅檢視";
  const appLink = `beartravel://invite?token=${token}`;
  return page(
    `加入 ${data.trip_name}`,
    `<p class="muted">${escape(data.inviter ?? "旅伴")} 邀請你加入</p>
<h1>${escape(data.trip_name)}</h1>
<p>${escape(data.start_date)} – ${escape(data.end_date)}<br><span class="muted">權限：${role}</span></p>
<a class="button" href="${appLink}">在 BeaRTravel 開啟</a>
<p class="muted">需要先安裝 BeaRTravel 並登入。</p>`,
  );
});
