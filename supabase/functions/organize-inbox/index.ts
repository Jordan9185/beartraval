// POST { capture_id }。JWT/RLS 驗證後，背景整理個人收件；不寫共同 Trip。
import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";
import { organizeCapture } from "../../../ai/inbox-organize/src/organize.ts";

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
    .select("id,owner_id,title,raw_text,status").eq("id", captureId).maybeSingle();
  if (error) return json({ error: "UNAUTHENTICATED" }, 401);
  if (!capture) return json({ error: "NOT_FOUND" }, 404);
  if (capture.status === "ready" || capture.status === "insufficient") return json({ status: capture.status });

  const admin = createClient(endpoint, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "app" } });
  const { data: attempt, error: claimError } = await admin.rpc("begin_inbox_analysis", { p_capture_id: captureId });
  if (claimError) return json({ error: "CLAIM_FAILED" }, 500);
  if (!attempt) return json({ status: "processing" });

  const work = async () => {
    const record = async (result: unknown, failure: string | null, model: string | null) => {
      const { error: saveError } = await admin.rpc("finish_inbox_analysis", {
        p_capture_id: captureId, p_attempt: attempt, p_result: result,
        p_error: failure, p_model: model,
      });
      if (saveError) throw saveError;
    };
    try {
      const { data: assets, error: assetError } = await admin.from("inbox_assets")
        .select("storage_path,kind,status").eq("capture_id", captureId).eq("kind", "image").eq("status", "uploaded")
        .order("ordinal", { ascending: true }).limit(10);
      if (assetError) throw assetError;
      const images: string[] = [];
      for (const asset of assets ?? []) {
        if (!asset.storage_path) continue;
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
      // 只有 URL、一般平台標題或影片檔但無可讀內容時，保留來源而不猜地點。
      const meaningful = rawText.replace(/https?:\/\/\S+/gi, "").trim() ||
        (title && !/^(Instagram|Threads|TikTok|YouTube)$/i.test(title.trim()) ? title.trim() : "");
      if (!meaningful && images.length === 0) {
        await record({ content_kind: "unknown", items: [], template_days: [] }, null, null);
        return;
      }
      const key = Deno.env.get("ANTHROPIC_API_KEY");
      if (!key) { await record(null, "missing_api_key", null); return; }
      const { data: allowed } = await asUser.rpc("consume_ai_quota", { p_kind: "inbox" });
      if (allowed !== true) { await record(null, "rate_limited", null); return; }
      const outcome = await organizeCapture(new Anthropic({ apiKey: key }),
        { title, rawText, imageBase64: images }, Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5");
      await record(outcome.result, null, outcome.model);
      console.log("organize-inbox", { capture_id: captureId, status: "ready", items: outcome.result.items.length });
    } catch (failure) {
      console.error("organize-inbox", { capture_id: captureId, error: failure instanceof Error ? failure.name : "unknown" });
      try { await record(null, "provider_error", null); } catch { /* 下次可重試 */ }
    }
  };
  EdgeRuntime.waitUntil(work());
  return json({ status: "processing" }, 202);
});
