import assert from "node:assert/strict";
import { test } from "node:test";
import { SEOUL } from "../eval/cases.ts";
import { AssistantAnswer, TripContext } from "../src/schema.ts";
import { validateAnswer } from "../src/validate.ts";

const base: AssistantAnswer = { answer: "ok", cannot_determine: false, citations: [], proposal: null };

test("eval context satisfies the schema", () => {
  TripContext.parse(SEOUL);
});

test("unknown citations are dropped", () => {
  const { answer, issues } = validateAnswer(SEOUL, { ...base, citations: [{ type: "saved", id: "sv1" }, { type: "stop", id: "nope" }] });
  assert.deepEqual(answer.citations, [{ type: "saved", id: "sv1" }]);
  assert.equal(issues.length, 1);
});

test("proposal for an unconfirmed place is removed", () => {
  const { answer } = validateAnswer(SEOUL, { ...base, proposal: { day_id: "day2", saved_id: "sv3", reason: "x" } });
  assert.equal(answer.proposal, null);
});

test("proposal with unknown day is removed", () => {
  const { answer } = validateAnswer(SEOUL, { ...base, proposal: { day_id: "day9", saved_id: "sv1", reason: "x" } });
  assert.equal(answer.proposal, null);
});

test("cannot_determine never carries a proposal", () => {
  const { answer } = validateAnswer(SEOUL, { ...base, cannot_determine: true, proposal: { day_id: "day3", saved_id: "sv1", reason: "x" } });
  assert.equal(answer.proposal, null);
});

test("valid proposal is kept", () => {
  const { answer, issues } = validateAnswer(SEOUL, { ...base, proposal: { day_id: "day1", saved_id: "sv2", reason: "最順路" } });
  assert.deepEqual(answer.proposal, { day_id: "day1", saved_id: "sv2", reason: "最順路" });
  assert.deepEqual(issues, []);
});

test("empty answer becomes cannot_determine", () => {
  const { answer } = validateAnswer(SEOUL, { ...base, answer: "  " });
  assert.equal(answer.cannot_determine, true);
});

test("schema has no field that could write the itinerary", () => {
  assert.deepEqual(Object.keys(AssistantAnswer.shape).sort(), ["answer", "cannot_determine", "citations", "proposal"]);
});
