import { enqueuePersonalAI, reply } from "../_shared/personal-ai.ts";
Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);
  const auth = req.headers.get("Authorization");
  if (!auth) return reply({ error: "UNAUTHENTICATED" }, 401);
  let body;
  try { body = await req.json(); } catch { return reply({ error: "INVALID_REQUEST" }, 400); }
  if (typeof body.raw_text !== "string" || !body.raw_text.trim() || body.raw_text.length > 20000) return reply({ error: "INVALID_REQUEST" }, 422);
  return enqueuePersonalAI(auth, "prepare", { rawText: body.raw_text });
});
