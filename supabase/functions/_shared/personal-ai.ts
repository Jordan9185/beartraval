import { createClient } from "@supabase/supabase-js";

export const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json" },
});
export const adminClient = () => createClient(Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "app" } });

// 每個入口先完成原有的 RLS／角色檢查，再把當下資料交給個人 Mac。
export async function enqueuePersonalAI(authorization: string, kind: string, input: unknown,
  context: Record<string, unknown> = {}): Promise<Response> {
  const admin = adminClient();
  const { data: auth, error } = await admin.auth.getUser(authorization.replace(/^Bearer\s+/i, ""));
  const owner = auth.user?.id;
  if (error || !owner) return reply({ error: "UNAUTHENTICATED" }, 401);
  if (owner !== Deno.env.get("PERSONAL_AI_OWNER_ID")) {
    return reply({ status: "failed", reason: "personal_ai_unavailable" });
  }
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([kind, input, context])));
  const key = Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
  const { data: job, error: enqueueError } = await admin.rpc("enqueue_personal_ai", {
    p_owner: owner, p_kind: kind, p_input: input, p_context: context, p_key: key,
  });
  if (enqueueError) {
    if (enqueueError.code === "PT429") return reply({ status: "failed", reason: "rate_limited" });
    if (enqueueError.message === "BUSY") return reply({ status: kind === "parse" ? "parsing" : "processing" }, 202);
    console.error("personal-ai enqueue", { kind, code: enqueueError.code });
    return reply({ status: "failed", reason: "queue_error" }, 503);
  }
  if (job.result) return reply(job.result);
  return reply({ status: "queued", job_id: job.id, reason: "personal_ai_waiting" }, 202);
}
