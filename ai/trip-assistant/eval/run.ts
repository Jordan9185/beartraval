// Runs the assistant eval.
//
//   npm run eval            # calls the Claude API (needs ANTHROPIC_API_KEY; costs money)
//   npm run eval:dry        # scores reference answers built from expectations (no API)
//
// Writes full outputs to eval/results/<timestamp>.json (gitignored).

import Anthropic from "@anthropic-ai/sdk";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { askTrip, DEFAULT_MODEL } from "../src/ask.ts";
import type { AssistantAnswer } from "../src/schema.ts";
import { validateAnswer } from "../src/validate.ts";
import { CASES, type EvalCase } from "./cases.ts";
import { scoreCase, type CaseScore } from "./score.ts";

const { values: args } = parseArgs({
  options: {
    "dry-run": { type: "boolean", default: false },
    model: { type: "string", default: DEFAULT_MODEL },
    only: { type: "string" },
  },
});

// An ideal answer for the expectations: checks the scorer and validator, not the model.
function reference(c: EvalCase): AssistantAnswer {
  return {
    answer: c.expect.cannot_determine ? "無法從目前的行程資料判斷。" : "依行程資料整理如下。",
    cannot_determine: c.expect.cannot_determine,
    citations: (c.expect.must_cite ?? []).map((id) => ({
      type: id.startsWith("rf") ? "route_fact" : id.startsWith("sv") ? "saved" : id.startsWith("i") ? "shopping" : "stop",
      id,
    })),
    proposal: c.expect.proposal && c.expect.proposal !== "none" ? { ...c.expect.proposal, reason: "最順路" } : null,
  };
}

const cases = args.only ? CASES.filter((c) => args.only!.split(",").includes(c.id)) : CASES;
const client = args["dry-run"] ? null : new Anthropic();
const scores: CaseScore[] = [];
const outputs: unknown[] = [];

for (const c of cases) {
  const started = Date.now();
  if (!client) {
    const { answer } = validateAnswer(c.context, reference(c));
    scores.push(scoreCase(c, answer));
    continue;
  }
  const outcome = await askTrip(client, c.context, c.question, { model: args.model });
  const latencyMs = Date.now() - started;
  outputs.push({ id: c.id, latencyMs, outcome });
  if (outcome.status === "answered") {
    scores.push(scoreCase(c, outcome.answer));
  } else {
    scores.push({ id: c.id, cannotDetermineOK: false, citationsOK: false, proposalOK: false, phrasingOK: false, pass: false, notes: [outcome.reason] });
  }
}

for (const s of scores) console.log(`${s.pass ? "PASS" : "FAIL"} ${s.id}${s.notes.length ? "  " + s.notes.join("; ") : ""}`);
const passed = scores.filter((s) => s.pass).length;
const noData = scores.filter((s) => CASES.find((c) => c.id === s.id)!.expect.cannot_determine);
console.log(`\n${passed}/${scores.length} passed; 無法判斷 cases: ${noData.filter((s) => s.cannotDetermineOK).length}/${noData.length}`);

if (client) {
  const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "results");
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, `${new Date().toISOString().replace(/[:.]/g, "-")}.json`), JSON.stringify({ model: args.model, scores, outputs }, null, 2));
}
process.exitCode = passed === scores.length ? 0 : 1;
