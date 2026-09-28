import type Anthropic from "@anthropic-ai/sdk";
import { codexClient, type Config } from "./codex.ts";
import { dispatchTask } from "../../shared/tasks.ts";

// 圖片上的小字與貼文邊界需要較完整推理；文字整理仍使用較省額度的模型。
export async function processTask(config: Config, job: { kind: string; input: any }, signal?: AbortSignal) {
  const hasImages = (job.kind === "inbox" && job.input.imageBase64?.length > 0) ||
    (job.kind === "extract" && !!job.input.imageBase64);
  const chosen = hasImages && config.visionModel ? { ...config, model: config.visionModel, reasoningEffort: "medium" as const } : config;
  const result = await dispatchTask(codexClient(chosen, signal) as unknown as Anthropic, job, `codex/${chosen.model}`);
  return { ...result, model: `codex/${chosen.model}` };
}
