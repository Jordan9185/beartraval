import type Anthropic from "@anthropic-ai/sdk";
import { createItineraryDraft } from "../../itinerary-parse/src/complete.ts";
import { askTrip } from "../../trip-assistant/src/ask.ts";
import { extractProducts } from "../../product-extract/src/extract.ts";
import { organizeCapture } from "../../inbox-organize/src/organize.ts";
import { discoverPlaces } from "../../inbox-organize/src/discover.ts";
import { codexClient, type Config } from "./codex.ts";

async function dispatch(config: Config, job: { kind: string; input: any }, signal?: AbortSignal) {
  const client = codexClient(config, signal) as unknown as Anthropic;
  const options = { model: `codex/${config.model}` };
  switch (job.kind) {
    case "parse": {
      const outcome = await createItineraryDraft(client, job.input, options);
      return outcome.status === "failed" ? outcome : {
        status: "parsed", parse_result: { draft: outcome.result, issues: outcome.issues },
      };
    }
    case "ask": {
      const outcome = await askTrip(client, job.input.context, job.input.question, options);
      return outcome.status === "failed" ? outcome : { status: "answered", answer: outcome.answer };
    }
    case "extract": {
      const outcome = await extractProducts(client, job.input, options);
      return outcome.status === "failed" ? outcome : {
        status: "extracted", products: outcome.result.products, warnings: outcome.result.warnings,
      };
    }
    case "inbox": {
      const input = job.input;
      const meaningful = input.rawText.replace(/https?:\/\/\S+/gi, "").trim() || input.publicText ||
        (input.title && !/^(Instagram|Threads|TikTok|YouTube)$/i.test(input.title.trim()));
      if (!meaningful && !input.imageBase64.length) return { status: "ready",
        result: { content_kind: "unknown", items: [], template_days: [] } };
      const outcome = await organizeCapture(client, input, options.model);
      return { status: "ready", result: outcome.result };
    }
    case "discover": {
      const candidates = await discoverPlaces(client, job.input.query, job.input.context, options.model, job.input.purpose);
      return { status: candidates.length ? "found" : "none", candidates, checked_at: new Date().toISOString() };
    }
    default: throw new Error("unsupported_task");
  }
}

// 圖片上的小字與貼文邊界需要較完整推理；文字整理仍使用較省額度的模型。
export async function processTask(config: Config, job: { kind: string; input: any }, signal?: AbortSignal) {
  const hasImages = (job.kind === "inbox" && job.input.imageBase64?.length > 0) ||
    (job.kind === "extract" && !!job.input.imageBase64);
  const chosen = hasImages && config.visionModel ? { ...config, model: config.visionModel, reasoningEffort: "medium" as const } : config;
  const result = await dispatch(chosen, job, signal);
  return { ...result, model: `codex/${chosen.model}` };
}
