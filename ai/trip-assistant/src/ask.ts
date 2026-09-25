// Calls Claude for a trip-scoped answer, then validates it against the trip
// data. Shared by the ask-trip Edge Function and the eval harness.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { SYSTEM_PROMPT, userMessage } from "./prompt.ts";
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
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: userMessage(context, question) }],
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
  return {
    status: "answered",
    answer,
    issues,
    model: response.model,
    usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
  };
}
