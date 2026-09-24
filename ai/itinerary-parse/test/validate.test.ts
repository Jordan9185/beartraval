import assert from "node:assert/strict";
import { test } from "node:test";
import { tripCalendar } from "../src/prompt.ts";
import { ParseResult, type ParseInput, type ParsedStop } from "../src/schema.ts";
import { isCleanStop, validateDraft } from "../src/validate.ts";
import { CASES } from "../eval/cases.ts";
import { scoreCase } from "../eval/score.ts";

const input: ParseInput = {
  tripStart: "2026-10-01",
  tripEnd: "2026-10-04",
  timeZone: "Asia/Seoul",
  rawText: "10/2 14:00 XXX Shoes\n10/2 晚上 明洞夜市",
};

function stop(overrides: Partial<ParsedStop> = {}): ParsedStop {
  return {
    source_excerpt: "14:00 XXX Shoes",
    place_name: "XXX Shoes",
    branch_hint: null,
    search_query: "XXX Shoes Seoul",
    category: "shop",
    start_time: "14:00",
    end_time: null,
    time_is_approximate: false,
    fixed_suspected: false,
    fixed_reason: null,
    confidence: "high",
    needs_confirmation: [],
    ...overrides,
  };
}

function draft(date: string | null, stops: ParsedStop[]) {
  return ParseResult.parse({ days: [{ date, day_label: null, stops }], city_candidates: ["Seoul"], warnings: [] });
}

test("clean stop passes unchanged", () => {
  const { result, issues } = validateDraft(input, draft("2026-10-02", [stop()]));
  assert.deepEqual(issues, []);
  assert.ok(isCleanStop(result.days[0]!.stops[0]!));
});

test("date outside trip is flagged ambiguous_date", () => {
  const { result, issues } = validateDraft(input, draft("2026-10-06", [stop()]));
  assert.equal(issues.length, 1);
  assert.deepEqual(result.days[0]!.stops[0]!.needs_confirmation, ["ambiguous_date"]);
});

test("undated day flags its stops", () => {
  const { result } = validateDraft(input, draft(null, [stop()]));
  assert.deepEqual(result.days[0]!.stops[0]!.needs_confirmation, ["ambiguous_date"]);
});

test("malformed time is cleared and flagged", () => {
  const { result, issues } = validateDraft(input, draft("2026-10-02", [stop({ start_time: "2pm" })]));
  assert.equal(result.days[0]!.stops[0]!.start_time, null);
  assert.ok(result.days[0]!.stops[0]!.needs_confirmation.includes("ambiguous_time"));
  assert.equal(issues[0]!.path, "days[0].stops[0].start_time");
});

test("end before start is flagged", () => {
  const { result } = validateDraft(input, draft("2026-10-02", [stop({ end_time: "13:00" })]));
  assert.ok(result.days[0]!.stops[0]!.needs_confirmation.includes("ambiguous_time"));
});

test("excerpt not in input lowers confidence", () => {
  const { result, issues } = validateDraft(input, draft("2026-10-02", [stop({ source_excerpt: "made up" })]));
  assert.equal(result.days[0]!.stops[0]!.confidence, "low");
  assert.equal(issues[0]!.issue, "excerpt not found in input");
});

test("stop without a place name needs confirmation", () => {
  const { result } = validateDraft(input, draft("2026-10-02", [stop({ place_name: null })]));
  assert.ok(result.days[0]!.stops[0]!.needs_confirmation.includes("unknown_place"));
  assert.ok(!isCleanStop(result.days[0]!.stops[0]!));
});

test("validation does not mutate the model draft", () => {
  const original = draft("2026-10-06", [stop()]);
  validateDraft(input, original);
  assert.deepEqual(original.days[0]!.stops[0]!.needs_confirmation, []);
});

test("trip calendar lists weekdays", () => {
  assert.deepEqual(tripCalendar("2026-10-01", "2026-10-02"), ["2026-10-01 (Thu)", "2026-10-02 (Fri)"]);
});

test("scorer: missing ambiguous_branch flag is a failure (AC-01)", () => {
  const c = CASES.find((x) => x.id === "seoul-line-chat-ambiguous-branch")!;
  const result = ParseResult.parse({
    days: [
      { date: "2026-10-02", day_label: "10/2", stops: [
        stop({ source_excerpt: "XXX Shoes", needs_confirmation: [] }),
        stop({ source_excerpt: "Jungsik", place_name: "Jungsik", start_time: "19:00", fixed_suspected: true }),
      ] },
      { date: "2026-10-03", day_label: "10/3", stops: [
        stop({ source_excerpt: "廣藏市場", place_name: "廣藏市場", start_time: "08:00", needs_confirmation: ["ambiguous_time"] }),
      ] },
    ],
    city_candidates: [],
    warnings: [],
  });
  const s = scoreCase(c, result);
  assert.deepEqual(s.stopRecall, [3, 3]);
  assert.deepEqual(s.flags, [1, 2]);
  assert.ok(s.failures.some((f) => f.includes("ambiguous_branch")));
});

test("scorer: non-stop leaking into a place name is caught", () => {
  const c = CASES.find((x) => x.id === "no-places")!;
  const s = scoreCase(c, draft(null, [stop({ place_name: "護照" })]));
  assert.deepEqual(s.mustNotInclude, [2, 3]);
  assert.equal(s.extraStops, 1);
});
