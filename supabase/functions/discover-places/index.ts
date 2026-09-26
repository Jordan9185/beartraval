// 從尚未確認的收藏線索查近期公開網頁，回傳具來源的餐廳名稱。
// 不寫入正式地點或座標；定位仍由 App 的地點服務與使用者確認。
import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";
import { discoverPlaces } from "../../../ai/inbox-organize/src/discover.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "UNAUTHENTICATED" }, 401);
  let itemID: string | null = null;
  let query: string | null = null;
  let context = "";
  let force = false;
  let purpose: "place" | "product_store" = "place";
  try {
    const body = await req.json();
    itemID = typeof body.item_id === "string" ? body.item_id : null;
    query = typeof body.query === "string" ? body.query.trim() : null;
    context = typeof body.context === "string" ? body.context.slice(0, 1000) : "";
    force = body.force === true;
    if (body.purpose === "product_store") purpose = "product_store";
  }
  catch { return json({ error: "INVALID_REQUEST" }, 400); }
  if ((itemID && !UUID.test(itemID)) || (!itemID && (!query || query.length < 2 || query.length > 200))) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  if (itemID && purpose !== "place") return json({ error: "INVALID_REQUEST" }, 400);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } }, db: { schema: "app" },
  });
  let item: { id: string; revision: number; display_name: string; source_span: string;
    discovery_candidates: unknown[] | null; discovery_checked_at: string | null } | null = null;
  if (itemID) {
    const { data: found, error } = await db.from("inbox_items")
      .select("id,capture_id,kind,display_name,source_span,revision,discovery_candidates,discovery_checked_at")
      .eq("id", itemID).maybeSingle();
    if (error) return json({ error: "UNAUTHENTICATED" }, 401);
    if (!found || found.kind !== "place") return json({ error: "NOT_FOUND" }, 404);
    item = found;
    if (!force && found.discovery_checked_at && Date.now() - Date.parse(found.discovery_checked_at) < 24 * 60 * 60 * 1000) {
      return json({ status: found.discovery_candidates?.length ? "found" : "none",
        candidates: found.discovery_candidates ?? [], checked_at: found.discovery_checked_at });
    }
    const { data: capture, error: captureError } = await db.from("inbox_captures")
      .select("raw_text,public_text,title").eq("id", found.capture_id).maybeSingle();
    if (captureError || !capture) return json({ error: "NOT_FOUND" }, 404);
    query = found.display_name;
    context = [capture.title, capture.public_text, capture.raw_text, found.source_span]
      .filter(Boolean).join("\n").slice(0, 1000);
  } else {
    // 收藏頁直接辨識截圖時尚未建立個人收件項目；先驗證 JWT 再按同一額度搜尋。
    const token = authorization.replace(/^Bearer\s+/i, "");
    const { data: auth, error } = await db.auth.getUser(token);
    if (error || !auth.user) return json({ error: "UNAUTHENTICATED" }, 401);
  }
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ status: "failed", reason: "missing_api_key" });
  const { data: allowed, error: quotaError } = await db.rpc("consume_ai_quota", { p_kind: "inbox" });
  if (quotaError) return json({ status: "failed", reason: "quota_error" });
  if (allowed !== true) return json({ status: "failed", reason: "rate_limited" });
  try {
    const candidates = await discoverPlaces(new Anthropic({ apiKey: key }), query!,
      context, Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5", purpose);
    const checkedAt = new Date().toISOString();
    if (item) {
      const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        { db: { schema: "app" } });
      const { error: saveError } = await admin.from("inbox_items")
        .update({ discovery_candidates: candidates, discovery_checked_at: checkedAt })
        .eq("id", item.id).eq("revision", item.revision);
      if (saveError) console.warn("discover-places cache not saved", { item_id: item.id });
    }
    console.log("discover-places", { item_id: itemID, purpose, candidates: candidates.length });
    return json({ status: candidates.length > 0 ? "found" : "none", candidates, checked_at: checkedAt });
  } catch (failure) {
    const providerStatus = failure instanceof Anthropic.APIError ? failure.status : null;
    console.error("discover-places", { item_id: itemID, status: providerStatus,
      error: failure instanceof Error ? failure.name : "unknown" });
    return json({ status: "failed", reason: providerStatus === 400 ? "search_unavailable" : "provider_error" });
  }
});
