// Calls Claude to turn pasted itinerary text into a draft, then validates the
// draft against the input. Shared by the AI Gateway (Supabase Edge Function)
// and the eval harness.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { SYSTEM_PROMPT, userMessage } from "./prompt.ts";
import { ParseResult, type ParseInput } from "./schema.ts";
import { validateDraft, type ValidationIssue } from "./validate.ts";

export const DEFAULT_MODEL = "claude-opus-5";

export interface ParseOptions {
  model?: string;
  effort?: "low" | "medium" | "high" | "xhigh" | "max";
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
  const response = await client.beta.messages.parse({
    model: options.model ?? DEFAULT_MODEL,
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    thinking: { type: "adaptive" },
    output_config: {
      format: betaZodOutputFormat(ParseResult),
      ...(options.effort ? { effort: options.effort } : {}),
    },
    system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: userMessage(input) }],
  });

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
