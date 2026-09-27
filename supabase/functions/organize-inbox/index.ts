import { enqueuePersonalAI } from "../_shared/personal-ai.ts";
// POST { capture_id }。JWT/RLS 驗證後，背景整理個人收件；不寫共同 Trip。
import { createClient } from "@supabase/supabase-js";
import { publicThreadsPost } from "../../../ai/inbox-organize/src/public-post.ts";


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
  let stage = "assets";
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
      return enqueuePersonalAI(authorization, "inbox",
        { title, rawText, publicText, imageBase64: images }, { capture_id: captureId });

    } catch {
      console.error("organize-inbox", { stage, status: "queue_error" });
      return json({ status: "failed", reason: "queue_error" }, 503);
    }
});
