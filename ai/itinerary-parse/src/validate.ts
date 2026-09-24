// Checks a model draft against the input it came from. The model's output is
// never trusted as fact: anything that doesn't hold up is downgraded to
// "needs confirmation" rather than silently accepted.

import type { ConfirmationReason, ParseInput, ParseResult, ParsedStop } from "./schema.ts";

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export interface ValidationIssue {
  path: string;
  issue: string;
}

export interface ValidatedResult {
  result: ParseResult;
  issues: ValidationIssue[];
}

// Collapses whitespace so excerpts survive line-wrapping differences.
function squash(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function addReason(stop: ParsedStop, reason: ConfirmationReason): void {
  if (!stop.needs_confirmation.includes(reason)) stop.needs_confirmation.push(reason);
}

export function validateDraft(input: ParseInput, draft: ParseResult): ValidatedResult {
  const result: ParseResult = structuredClone(draft);
  const issues: ValidationIssue[] = [];
  const haystack = squash(input.rawText);

  result.days.forEach((day, d) => {
    const dayPath = `days[${d}]`;
    if (day.date !== null) {
      const valid = DATE_RE.test(day.date) && !Number.isNaN(Date.parse(day.date));
      if (!valid || day.date < input.tripStart || day.date > input.tripEnd) {
        issues.push({ path: `${dayPath}.date`, issue: `date ${day.date} is not within the trip` });
        day.stops.forEach((s) => addReason(s, "ambiguous_date"));
      }
    } else {
      day.stops.forEach((s) => addReason(s, "ambiguous_date"));
    }

    day.stops.forEach((stop, i) => {
      const path = `${dayPath}.stops[${i}]`;

      for (const key of ["start_time", "end_time"] as const) {
        const t = stop[key];
        if (t !== null && !TIME_RE.test(t)) {
          issues.push({ path: `${path}.${key}`, issue: `invalid time ${t}` });
          stop[key] = null;
          addReason(stop, "ambiguous_time");
        }
      }
      if (stop.start_time && stop.end_time && stop.end_time <= stop.start_time) {
        issues.push({ path, issue: "end_time is not after start_time" });
        addReason(stop, "ambiguous_time");
      }

      if (!haystack.includes(squash(stop.source_excerpt))) {
        issues.push({ path: `${path}.source_excerpt`, issue: "excerpt not found in input" });
        stop.confidence = "low";
      }

      if (stop.place_name === null && stop.category !== "transport") {
        addReason(stop, "unknown_place");
      }
    });
  });

  return { result, issues };
}

// True when a stop may go straight into a Place lookup without extra questions.
export function isCleanStop(stop: ParsedStop): boolean {
  return stop.needs_confirmation.length === 0 && stop.place_name !== null;
}
