// Calls Claude to list products in a shared post, then validates the list.
// Used by the extract-products Edge Function.

import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { SYSTEM_PROMPT, userText } from "./prompt.ts";
import { ExtractResult, type ExtractInput } from "./schema.ts";
import { validateProducts, type ValidationIssue } from "./validate.ts";

export const DEFAULT_MODEL = "claude-opus-5-5";
// Reading one post; medium keeps the share sheet responsive.
export const DEFAULT_EFFORT = "medium" as const;

export type ExtractOutcome =
  | { status: "extracted"; result: ExtractResult; issues: ValidationIssue[]; model: string }
  | { status: "failed"; reason: "refusal" | "max_tokens" | "invalid_output" };

export async function extractProducts(
  client: Anthropic,
  input: ExtractInput,
  options: { model?: string } = {},
): Promise<ExtractOutcome> {
  const content: Anthropic.Beta.Messages.BetaContentBlockParam[] = [];
  if (input.imageBase64) {
    content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: input.imageBase64 } });
  }
  content.push({ type: "text", text: userText(input) });

  let response;
  try {
    response = await client.beta.messages.parse({
      model: options.model ?? DEFAULT_MODEL,
      max_tokens: 8000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      thinking: { type: "adaptive" },
      output_config: { format: betaZodOutputFormat(ExtractResult), effort: DEFAULT_EFFORT },
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content }],
    });
  } catch (error) {
    // The SDK throws when the structured output isn't valid JSON (cut off, refusal).
    if (error instanceof Error && error.message.startsWith("Failed to parse structured output")) {
      return { status: "failed", reason: "invalid_output" };
    }
    throw error;
  }

  if (response.stop_reason === "refusal") return { status: "failed", reason: "refusal" };
  if (response.stop_reason === "max_tokens") return { status: "failed", reason: "max_tokens" };
  const check = response.parsed_output ? ExtractResult.safeParse(response.parsed_output) : null;
  if (!check?.success) return { status: "failed", reason: "invalid_output" };
  const { result, issues } = validateProducts(input, check.data);
  return { status: "extracted", result, issues, model: response.model };
}
