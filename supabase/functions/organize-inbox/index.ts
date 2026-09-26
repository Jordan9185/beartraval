// POST { capture_id }。JWT/RLS 驗證後，背景整理個人收件；不寫共同 Trip。
import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";
import { organizeCapture } from "../../../ai/inbox-organize/src/organize.ts";
import { publicThreadsPost } from "../../../ai/inbox-organize/src/public-post.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "UNAUTHENTICATED" }, 401);
  let captureId: string;
  try { captureId = (await req.json()).capture_id; }
  catch { return json({ error: "INVALID_REQUEST" }, 400); }
  if (typeof captureId !== "string" || !UUID.test(captureId)) return json({ error: "INVALID_REQUEST" }, 400);

  const endpoint = Deno.env.get("SUPABASE_URL")!;
  const asUser = createClient(endpoint, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } }, db: { schema: "app" },
  });
  const { data: capture, error } = await asUser.from("inbox_captures")
    .select("id,owner_id,title,raw_text,source_url,public_text,status").eq("id", captureId).maybeSingle();
  if (error) return json({ error: "UNAUTHENTICATED" }, 401);
  if (!capture) return json({ error: "NOT_FOUND" }, 404);
  if (capture.status === "ready") return json({ status: capture.status });

  const admin = createClient(endpoint, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "app" } });
  const { data: attempt, error: claimError } = await admin.rpc("begin_inbox_analysis", { p_capture_id: captureId });
  if (claimError) return json({ error: "CLAIM_FAILED" }, 500);
  if (!attempt) return json({ status: "processing" });

  const work = async () => {
    let stage = "assets";
    const record = async (result: unknown, failure: string | null, model: string | null) => {
      const { data: saved, error: saveError } = await admin.rpc("finish_inbox_analysis", {
        p_capture_id: captureId, p_attempt: attempt, p_result: result,
        p_error: failure, p_model: model,
      });
      if (saveError) throw saveError;
      return saved === true;
    };
    try {
      const { data: assets, error: assetError } = await admin.from("inbox_assets")
        .select("storage_path,kind,status").eq("capture_id", captureId).eq("kind", "image").eq("status", "uploaded")
        .order("ordinal", { ascending: true }).limit(10);
      if (assetError) throw assetError;
      const images: string[] = [];
      for (const asset of assets ?? []) {
        if (!asset.storage_path) continue;
        stage = "download";
        const { data: blob, error: downloadError } = await admin.storage.from("inbox-images").download(asset.storage_path);
        if (downloadError || !blob) throw new Error("asset_unavailable");
        const bytes = new Uint8Array(await blob.arrayBuffer());
        if (bytes.length > 2_000_000) throw new Error("image_too_large");
        let binary = "";
        for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
        images.push(btoa(binary));
      }
      const rawText: string = capture.raw_text ?? "";
      const title: string | null = capture.title ?? null;
      // 原始分享文字與公開頁面的摘要分開存，不能拿爬到的內容冒充 App 提供的 payload。
      let publicText: string | null = capture.public_text ?? null;
      if (!publicText && capture.source_url) {
        stage = "public_metadata";
        try {
          const post = await publicThreadsPost(capture.source_url);
          if (post) {
            publicText = post.text;
            const { error: updateError } = await admin.from("inbox_captures")
              .update({ public_text: post.text, resolved_source_url: post.resolvedURL }).eq("id", captureId);
            if (updateError) throw updateError;
          }
        } catch { /* 公開頁面不可讀時只依實際分享內容整理。 */ }
      }
      // 只有 URL、一般平台標題或影片檔但無可讀內容時，保留來源而不猜地點。
      const meaningful = rawText.replace(/https?:\/\/\S+/gi, "").trim() ||
        (title && !/^(Instagram|Threads|TikTok|YouTube)$/i.test(title.trim()) ? title.trim() : "");
      if (!meaningful && !publicText && images.length === 0) {
        await record({ content_kind: "unknown", items: [], template_days: [] }, null, null);
        return;
      }
      const key = Deno.env.get("ANTHROPIC_API_KEY");
      if (!key) { await record(null, "missing_api_key", null); return; }
      stage = "quota";
      const { data: allowed, error: quotaError } = await asUser.rpc("consume_ai_quota", { p_kind: "inbox" });
      if (quotaError) throw quotaError;
      if (allowed !== true) { await record(null, "rate_limited", null); return; }
      stage = "model";
      const outcome = await organizeCapture(new Anthropic({ apiKey: key }),
        { title, rawText, publicText, imageBase64: images }, Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5");
      stage = "save";
      const saved = await record(outcome.result, null, outcome.model);
      if (saved) {
        for (const [ordinal, item] of outcome.result.items.entries()) {
          if (item.kind !== "product" || !item.store_hint) continue;
          const { error: hintError } = await admin.from("inbox_items")
            .update({ store_hint: item.store_hint, store_evidence: item.store_evidence })
            .eq("capture_id", captureId).eq("ordinal", ordinal).eq("user_corrected", false);
          if (hintError) console.warn("organize-inbox store hint not saved", { capture_id: captureId, ordinal });
        }
      }
      console.log("organize-inbox", { capture_id: captureId, status: "ready", items: outcome.result.items.length });
    } catch (failure) {
      const status = failure instanceof Anthropic.APIError ? failure.status : null;
      const databaseCode = typeof failure === "object" && failure !== null && "code" in failure &&
        typeof failure.code === "string" && /^[A-Z0-9]{5,12}$/.test(failure.code) ? failure.code : null;
      const code = status ? `${stage}_http_${status}` : databaseCode ? `${stage}_${databaseCode}` : `${stage}_error`;
      console.error("organize-inbox", { capture_id: captureId, stage, status,
        database_code: databaseCode, error: failure instanceof Error ? failure.name : "unknown" });
      try { await record(null, code, null); } catch { /* 下次可重試 */ }
    }
  };
  EdgeRuntime.waitUntil(work());
  return json({ status: "processing" }, 202);
});
