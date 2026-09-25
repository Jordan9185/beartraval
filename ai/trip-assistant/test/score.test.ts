import assert from "node:assert/strict";
import { test } from "node:test";
import { CASES, type EvalCase } from "../eval/cases.ts";
import { scoreCase } from "../eval/score.ts";
import type { AssistantAnswer } from "../src/schema.ts";

const byId = (id: string): EvalCase => CASES.find((c) => c.id === id)!;
const answer = (overrides: Partial<AssistantAnswer> = {}): AssistantAnswer => ({
  answer: "依行程資料整理如下。",
  cannot_determine: false,
  citations: [],
  proposal: null,
  ...overrides,
});

// The scorer must fail wrong answers, not only pass the reference ones.
test("scorer: a made-up answer to a no-data question fails", () => {
  const s = scoreCase(byId("weather"), answer({ answer: "明天首爾晴天。" }));
  assert.equal(s.pass, false);
  assert.equal(s.cannotDetermineOK, false);
  assert.ok(s.notes.some((n) => n.startsWith("cannot_determine")));
});

test("scorer: a missing citation fails", () => {
  const s = scoreCase(byId("fixed-today"), answer({ citations: [{ type: "stop", id: "s3" }] }));
  assert.equal(s.pass, false);
  assert.equal(s.citationsOK, false);
  assert.ok(s.notes.some((n) => n.includes("s5")));
});

test("scorer: a proposal for the wrong day or where none is allowed fails", () => {
  const wrongDay = scoreCase(byId("propose-olive"), answer({ proposal: { day_id: "day2", saved_id: "sv2", reason: "x" } }));
  assert.equal(wrongDay.proposalOK, false);
  assert.equal(wrongDay.pass, false);
  const unwanted = scoreCase(byId("bought"), answer({
    citations: [{ type: "shopping", id: "i2" }],
    proposal: { day_id: "day1", saved_id: "sv2", reason: "x" },
  }));
  assert.equal(unwanted.proposalOK, false);
  assert.equal(unwanted.pass, false);
});

test("scorer: a stock claim fails", () => {
  const s = scoreCase(byId("stock"), answer({ answer: "樂天免稅店有庫存。", cannot_determine: true }));
  assert.equal(s.phrasingOK, false);
  assert.equal(s.pass, false);
});

test("scorer: a correct answer passes", () => {
  const s = scoreCase(byId("fixed-today"), answer({ citations: [{ type: "stop", id: "s5" }] }));
  assert.equal(s.pass, true);
});
