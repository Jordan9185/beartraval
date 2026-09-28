import { citedSources, type SearchCitation } from "../../inbox-organize/src/discover.ts";
// Calls Claude for a trip-scoped answer, then validates it against the trip
// data. Shared by the ask-trip Edge Function and the eval harness.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { SYSTEM_PROMPT, userMessage, RESEARCH_RULES } from "./prompt.ts";
import { AssistantAnswer, type TripContext } from "./schema.ts";
import { validateAnswer, type ValidationIssue } from "./validate.ts";

export const DEFAULT_MODEL = "claude-sonnet-5";
// Trip Q&A reads already-structured data; medium effort keeps answers quick.
export const DEFAULT_EFFORT = "medium" as const;

export type AskOutcome =
  | {
      status: "answered";
      answer: AssistantAnswer;
      issues: ValidationIssue[];
      model: string;
      usage: { input_tokens: number; output_tokens: number };
    }
  | { status: "failed"; reason: "refusal" | "max_tokens" | "invalid_output"; detail?: string };

export async function askTrip(
  client: Anthropic,
  context: TripContext,
  question: string,
  options: { model?: string; effort?: "low" | "medium" | "high" | "xhigh" | "max" } = {},
): Promise<AskOutcome> {
  let research = "";
  let sources: SearchCitation[] = [];
  const checkedAt = new Date().toISOString();
  if (context.focus_stop_id) {
    const stop = context.days.flatMap((d) => d.stops).find((s) => s.id === context.focus_stop_id);
    const day = context.days.find((d) => d.stops.some((s) => s.id === context.focus_stop_id));
    if (!stop) return { status: "failed", reason: "invalid_output" };
    const searched = await client.messages.create({
      model: options.model ?? DEFAULT_MODEL, max_tokens: 3500,
      tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 3 }],
      system: RESEARCH_RULES + "只搜尋必要的公開店家資訊，不將旅伴名字、購物清單或整份行程送進搜尋關鍵字。以來源 citation 支持回答。",
      messages: [{ role: "user", content: JSON.stringify({ stop, date: day?.date, time_zone: context.trip.time_zone, question }) }],
    });
    sources = citedSources(searched);
    research = JSON.stringify({ sources, summary: searched.content.filter((b) => b.type === "text").map((b) => b.text).join("\n") });
  }
  let response;
  try {
    response = await client.beta.messages.parse({
      model: options.model ?? DEFAULT_MODEL,
      // Adaptive thinking counts toward max_tokens; leave room for it.
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      thinking: { type: "adaptive" },
      output_config: {
        format: betaZodOutputFormat(AssistantAnswer),
        effort: options.effort ?? DEFAULT_EFFORT,
      },
      system: [{ type: "text", text: SYSTEM_PROMPT + "\n" + RESEARCH_RULES, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: userMessage(context, question) + "\n已查得研究（僅來源內容可作事實）：" + research }],
    });
  } catch (error) {
    // The SDK throws when the structured output isn't valid JSON (cut off, refusal).
    if (error instanceof Error && error.message.startsWith("Failed to parse structured output")) {
      return { status: "failed", reason: "invalid_output" };
    }
    throw error;
  }

  if (response.stop_reason === "refusal") {
    return { status: "failed", reason: "refusal", detail: response.stop_details?.category ?? undefined };
  }
  if (response.stop_reason === "max_tokens") return { status: "failed", reason: "max_tokens" };

  const check = response.parsed_output ? AssistantAnswer.safeParse(response.parsed_output) : null;
  if (!check?.success) return { status: "failed", reason: "invalid_output", detail: check?.error.message };

  const { answer, issues } = validateAnswer(context, check.data);
  const focusDay = context.days.find((d) => d.stops.some((s) => s.id === context.focus_stop_id));
  const focusStop = focusDay?.stops.find((s) => s.id === context.focus_stop_id);
  verifyNearbyAnswer(answer, sources, focusStop?.label, focusDay?.date);
  answer.checked_at = checkedAt;
  return {
    status: "answered",
    answer,
    issues,
    model: response.model,
    usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
  };
}

export function verifiedRecommendations(items: NonNullable<AssistantAnswer["recommendations"]>, sources: SearchCitation[], originName?: string, visitDate?: string) {
  const evidenceMatches = (value: { source_url: string; evidence: string } | null) => {
    if (!value || !value.evidence.trim()) return false;
    return sources.some((s) => s.url === value.source_url && s.citedText.includes(value.evidence));
  };
  const validDate = (value: string) => /^\d{4}-\d{2}-\d{2}$/.test(value)
    && !Number.isNaN(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
  const eventMatches = (item: NonNullable<AssistantAnswer["recommendations"]>[number]) => {
    if (item.category !== "event") return true;
    const period = item.event_period;
    return !!(period && visitDate && validDate(visitDate) && validDate(period.start_date) && validDate(period.end_date)
      && evidenceMatches(period) && period.evidence.includes(item.name)
      && period.evidence.includes(period.start_date) && period.evidence.includes(period.end_date)
      && period.start_date <= visitDate && visitDate <= period.end_date);
  };
  return items.filter(eventMatches).filter((item) => sources.some((s) => s.url === item.source_url &&
    (s.citedText + " " + s.title).includes(item.name))).map((item) => ({
      ...item, address_local: item.address_local && sources.some((s) => s.url === item.source_url && s.citedText.includes(item.address_local!)) ? item.address_local : null,
      route: originName && evidenceMatches(item.route) && item.route?.evidence.includes(originName)
        && item.route.evidence.includes(item.name) && item.route.evidence.includes(item.route.description) ? item.route : null,
      rating: evidenceMatches(item.rating) && item.rating?.evidence.includes(item.rating.display)
        && (!item.rating.reviews || item.rating.evidence.includes(item.rating.reviews))
        && sources.some((s) => s.url === item.rating!.source_url && (s.title + " " + s.citedText + " " + s.url).includes(item.rating!.platform)) ? item.rating : null,
    }));
}

/** 引用被剔除時，自由文字也不能繼續保留同一筆未核實的分鐘、評分或活動。 */
export function verifyNearbyAnswer(answer: AssistantAnswer, sources: SearchCitation[], originName?: string, visitDate?: string): void {
  const original = answer.recommendations ?? [];
  const verified = verifiedRecommendations(original, sources, originName, visitDate);
  answer.recommendations = verified;
  if (original.length && JSON.stringify(original) !== JSON.stringify(verified)) {
    answer.answer = verified.length
      ? `已保留 ${verified.length} 個有來源的附近候選。部分地址、路程、評分或活動日期無法核實，請以候選卡片的已知與未知資料為準。`
      : "這次沒有取得足以核對的附近候選；店家、活動日期或相關來源仍待確認，沒有更動行程。";
    if (!verified.length) answer.cannot_determine = true;
  }
}
