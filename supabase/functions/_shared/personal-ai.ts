declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };
import { runClaudeJob } from "./claude-ai.ts";
import { createClient } from "@supabase/supabase-js";
import { personalAIUsers } from "./personal-ai-access.ts";

export const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json" },
});
export const adminClient = () => createClient(Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "app" } });
export const allowedPersonalAIUsers = () => personalAIUsers(Deno.env.get("PERSONAL_AI_ALLOWED_USER_IDS"),
  Deno.env.get("PERSONAL_AI_OWNER_ID"));

// 每個入口先完成原有的 RLS／角色檢查，再把當下資料交給個人 Mac。
export async function enqueuePersonalAI(authorization: string, kind: string, input: unknown,
  context: Record<string, unknown> = {}): Promise<Response> {
  const admin = adminClient();
  const { data: auth, error } = await admin.auth.getUser(authorization.replace(/^Bearer\s+/i, ""));
  const owner = auth.user?.id;
  if (error || !owner) return reply({ error: "UNAUTHENTICATED" }, 401);
  if (!allowedPersonalAIUsers().includes(owner)) {
    return reply({ status: "failed", reason: "personal_ai_unavailable" });
  }
  const { data: preference, error: preferenceError } = await admin.from("ai_preferences").select("provider").eq("user_id", owner).maybeSingle();
  if (preferenceError) return reply({ status: "failed", reason: "ai_settings_unavailable" }, 503);
  const provider = preference?.provider ?? "local_gpt";
  if (provider === "claude_api" && (!Deno.env.get("ANTHROPIC_API_KEY") || !Deno.env.get("CLAUDE_AI_MODEL"))) {
    return reply({ status: "failed", reason: "claude_api_not_configured" });
  }
  context = { ...context, ai_provider: provider };
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([kind, input, context])));
  const key = Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
  const payload = input as Record<string, unknown>;
  const label = String(payload.query ?? payload.tripName ?? payload.title ?? "").slice(0, 80);
  const { data: job, error: enqueueError } = await admin.rpc("enqueue_personal_ai", {
    p_owner: owner, p_kind: kind, p_input: input, p_context: { ...context, display_label: label }, p_key: key,
  });
  if (enqueueError) {
    if (enqueueError.code === "PT429") return reply({ status: "failed", reason: "rate_limited" });
    if (enqueueError.message === "BUSY") return reply({ status: kind === "parse" ? "parsing" : "processing" }, 202);
    console.error("personal-ai enqueue", { kind, code: enqueueError.code });
    return reply({ status: "failed", reason: "queue_error" }, 503);
  }
  if (job.result) return reply(job.result);
  if (provider === "claude_api" && job.status === "queued") {
    EdgeRuntime.waitUntil(runClaudeJob(admin, job.id));
  }
  return reply({ status: job.status, job_id: job.id, reason: job.reason ??
    (provider === "claude_api" ? "claude_api_running" : job.status === "running" ? "personal_ai_running" : "personal_ai_waiting") }, 202);
}
