// Checks an assistant answer against the context it was given. Anything that
// does not refer to real trip data is dropped rather than shown.

import type { AssistantAnswer, TripContext } from "./schema.ts";

export interface ValidationIssue {
  path: string;
  issue: string;
}

export function knownIds(context: TripContext): Record<string, Set<string>> {
  return {
    stop: new Set(context.days.flatMap((d) => d.stops.map((s) => s.id))),
    saved: new Set(context.saved.map((s) => s.id)),
    shopping: new Set(context.shopping.map((s) => s.id)),
    route_fact: new Set(context.route_facts.map((r) => r.id)),
  };
}

export function validateAnswer(context: TripContext, answer: AssistantAnswer): { answer: AssistantAnswer; issues: ValidationIssue[] } {
  const result: AssistantAnswer = structuredClone(answer);
  const issues: ValidationIssue[] = [];
  const ids = knownIds(context);

  result.citations = result.citations.filter((c, i) => {
    const ok = ids[c.type]?.has(c.id) ?? false;
    if (!ok) issues.push({ path: `citations[${i}]`, issue: `unknown ${c.type} ${c.id}` });
    return ok;
  });

  if (result.proposal) {
    const saved = context.saved.find((s) => s.id === result.proposal!.saved_id);
    const dayOK = context.days.some((d) => d.id === result.proposal!.day_id);
    if (result.cannot_determine) {
      issues.push({ path: "proposal", issue: "proposal with cannot_determine" });
      result.proposal = null;
    } else if (!saved || !dayOK) {
      issues.push({ path: "proposal", issue: "proposal refers to unknown day or saved place" });
      result.proposal = null;
    } else if (!saved.place_confirmed) {
      issues.push({ path: "proposal", issue: "proposal for an unconfirmed place" });
      result.proposal = null;
    }
  }

  if (result.answer.trim().length === 0) {
    issues.push({ path: "answer", issue: "empty answer" });
    result.cannot_determine = true;
    result.answer = "無法從目前的行程資料判斷。";
  }
  return { answer: result, issues };
}
