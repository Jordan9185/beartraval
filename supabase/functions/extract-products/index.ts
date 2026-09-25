// Products from a shared post for the shopping list.
// POST { trip_id, text?, url?, image_base64? } with the user's JWT.
//
// Only returns a draft list; nothing is written. The app shows it, the user
// picks and edits, then adds items with add_shopping_item. Only trip owners
// and editors may call it (RLS decides membership). Logs carry timings only.

import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";
import { extractProducts } from "../../../ai/product-extract/src/extract.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// About 1.5 MB of JPEG; the app sends a 1024 px image, well under this.
const MAX_IMAGE_BASE64 = 2_000_000;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "UNAUTHENTICATED" }, 401);

  let body: { trip_id?: string; text?: string; url?: string | null; image_base64?: string | null };
  try {
    body = await req.json();
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const text = (body.text ?? "").slice(0, 5000);
  const image = body.image_base64 ?? null;
  if (!body.trip_id || (text.trim().length === 0 && !image)) return json({ error: "INVALID_REQUEST" }, 400);
  if (image && (image.length > MAX_IMAGE_BASE64 || !/^[A-Za-z0-9+/=]+$/.test(image))) {
    return json({ error: "INVALID_IMAGE" }, 400);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const db = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    db: { schema: "app" },
  });
  const { data: role, error } = await db.rpc("trip_role_of", { p_trip_id: body.trip_id });
  if (error) return json({ error: "UNAUTHENTICATED" }, 401);
  if (role !== "owner" && role !== "editor") return json({ error: "FORBIDDEN" }, 403);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ status: "failed", reason: "missing_api_key" });

  const started = Date.now();
  try {
    const outcome = await extractProducts(new Anthropic({ apiKey }), {
      text,
      url: body.url ?? null,
      imageBase64: image,
    }, { model: Deno.env.get("ANTHROPIC_MODEL") || undefined });
    console.log("extract-products", { ms: Date.now() - started, status: outcome.status, image: Boolean(image) });
    if (outcome.status === "failed") return json({ status: "failed", reason: outcome.reason });
    return json({ status: "extracted", products: outcome.result.products, warnings: outcome.result.warnings });
  } catch (e) {
    console.error("extract-products failed", e instanceof Error ? e.message : e);
    return json({ status: "failed", reason: "provider_error" });
  }
});
