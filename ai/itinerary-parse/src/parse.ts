// Calls Claude to turn pasted itinerary text into a draft, then validates the
// draft against the input. Shared by the AI Gateway (Supabase Edge Function)
// and the eval harness.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { SYSTEM_PROMPT, userMessage } from "./prompt.ts";
import { ParseResult, type ParseInput } from "./schema.ts";
import { validateDraft, type ValidationIssue } from "./validate.ts";

export const DEFAULT_MODEL = "claude-opus-5-5";
// High effort took 2–5 minutes on a real 7-day plan, too long to wait on a phone
// and close to the Edge Function time limit; medium is Opus 5.5's default.
export const DEFAULT_EFFORT = "medium" as const;

export interface ParseProgress {
  // "reading" until the model starts writing the draft, then "writing".
  stage: "reading" | "writing";
  days: number;
  stops: number;
  last_place: string | null;
}

export interface ParseOptions {
  model?: string;
  effort?: "low" | "medium" | "high" | "xhigh" | "max";
  // Called as the draft streams in; counts come from the partial JSON text.
  onProgress?: (progress: ParseProgress) => void;
}

// Counts what the partial draft JSON contains so far.
export function progressOf(partialJson: string): ParseProgress {
  const names = [...partialJson.matchAll(/"place_name"\s*:\s*"((?:[^"\\]|\\.)*)"/g)];
  return {
    stage: "writing",
    days: (partialJson.match(/"day_label"\s*:/g) ?? []).length,
    stops: (partialJson.match(/"source_excerpt"\s*:/g) ?? []).length,
    last_place: unescape(names.at(-1)?.[1]),
  };
}

function unescape(raw: string | undefined): string | null {
  if (raw === undefined) return null;
  try {
    return JSON.parse(`"${raw}"`);
  } catch {
    return raw;
  }
}

export type ParseOutcome =
  | {
      status: "parsed";
      result: ParseResult;
      issues: ValidationIssue[];
      model: string;
      usage: { input_tokens: number; output_tokens: number };
    }
  // PARSE_FAILED (plan §3.5): the caller keeps the raw text and offers retry/edit.
  | { status: "failed"; reason: "refusal" | "max_tokens" | "invalid_output"; detail?: string };

export async function parseItinerary(
  client: Anthropic,
  input: ParseInput,
  options: ParseOptions = {},
): Promise<ParseOutcome> {
  // Streamed so long itineraries don't hit request timeouts and progress can be shown.
  const stream = client.beta.messages.stream({
    model: options.model ?? DEFAULT_MODEL,
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    thinking: { type: "adaptive" },
    output_config: {
      format: betaZodOutputFormat(ParseResult),
      effort: options.effort ?? DEFAULT_EFFORT,
    },
    system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: userMessage(input) }],
  });
  options.onProgress?.({ stage: "reading", days: 0, stops: 0, last_place: null });
  stream.on("text", (_delta, snapshot) => options.onProgress?.(progressOf(snapshot)));
  const response = await stream.finalMessage();

  if (response.stop_reason === "refusal") {
    return { status: "failed", reason: "refusal", detail: response.stop_details?.category ?? undefined };
  }
  if (response.stop_reason === "max_tokens") {
    return { status: "failed", reason: "max_tokens" };
  }

  const parsed = response.parsed_output;
  const check = parsed ? ParseResult.safeParse(parsed) : null;
  if (!check?.success) {
    return { status: "failed", reason: "invalid_output", detail: check?.error.message };
  }

  const { result, issues } = validateDraft(input, check.data);
  return {
    status: "parsed",
    result,
    issues,
    model: response.model,
    usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
  };
}
