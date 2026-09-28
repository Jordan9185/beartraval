import { prepareTrip } from "../itinerary-parse/src/prepare.ts";
import type Anthropic from "@anthropic-ai/sdk";
import { parseItinerary } from "../itinerary-parse/src/parse.ts";
import { askTrip } from "../trip-assistant/src/ask.ts";
import { extractProducts } from "../product-extract/src/extract.ts";
import { organizeCapture } from "../inbox-organize/src/organize.ts";
import { discoverPlaces } from "../inbox-organize/src/discover.ts";

export async function dispatchTask(client: Anthropic, job: { kind: string; input: any }, model: string) {
  const options = { model };
  switch (job.kind) {
    case "prepare": return prepareTrip(client, job.input.rawText, model);
    case "parse": {
      const outcome = await parseItinerary(client, job.input, options);
      return outcome.status === "failed" ? outcome : {
        status: "parsed", parse_result: { draft: outcome.result, issues: outcome.issues }, usage: [outcome.usage],
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
