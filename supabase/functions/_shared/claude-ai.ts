import Anthropic from "@anthropic-ai/sdk";
import { dispatchTask } from "../../../ai/shared/tasks.ts";
import type { adminClient } from "./personal-ai.ts";

// 從共用工作資料領取後執行；金鑰只在服務端。每次回應用量照實保存，失敗不等於未扣額度。
export async function runClaudeJob(admin: ReturnType<typeof adminClient>, id: string): Promise<void> {
  const { data: job, error } = await admin.rpc("claim_claude_ai", { p_id: id });
  if (error || !job?.id) return;
  const model = Deno.env.get("CLAUDE_AI_MODEL")!;
  const usages: unknown[] = [];
  const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY"), maxRetries: 0,
    timeout: 120_000,
    fetch: async (input, init) => {
      const response = await fetch(input, init);
      try {
        if (response.headers.get("content-type")?.includes("application/json")) {
          const body = await response.clone().json();
          if (body.usage) usages.push(body.usage);
        }
      } catch { /* 無回報就保留未知。 */ }
      return response;
    },
  });
  let result;
  try { result = await dispatchTask(client, job, model); }
  catch { result = { status: "failed", reason: "claude_api_error" }; }
  const { error: saveError } = await admin.rpc("finish_personal_ai", {
    p_owner: job.owner_id, p_id: job.id, p_lease: job.lease,
    p_result: { ...result, provider: "claude_api", usage: usages.length ? usages : "usage" in result ? result.usage : null, model }, p_model: model,
  });
  if (saveError) console.error("claude-ai save failed", { code: saveError.code });
}
