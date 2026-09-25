// Runs the parsing eval.
//
//   npm run eval                 # calls the Claude API (needs credentials; costs money)
//   npm run eval -- --effort medium --only seoul-korean
//   npm run eval:dry             # scores perfect drafts built from expectations (no API)
//
// Writes the full outputs to eval/results/<timestamp>.json.

import Anthropic from "@anthropic-ai/sdk";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { DEFAULT_MODEL, parseItinerary, type ParseOptions } from "../src/parse.ts";
import type { ParseResult, ParsedDay } from "../src/schema.ts";
import { CASES, type EvalCase } from "./cases.ts";
import { pct, scoreCase, sumScores, type CaseScore } from "./score.ts";

const { values: args } = parseArgs({
  options: {
    "dry-run": { type: "boolean", default: false },
    model: { type: "string", default: DEFAULT_MODEL },
    effort: { type: "string" },
    only: { type: "string" },
    concurrency: { type: "string", default: "4" },
  },
});

// A perfect draft for the expectations: checks the scorer, not the model.
function draftFromExpectations(c: EvalCase): ParseResult {
  const days = new Map<string | null, ParsedDay>();
  for (const e of c.expected) {
    const day = days.get(e.date) ?? { date: e.date, day_label: null, stops: [] };
    day.stops.push({
      source_excerpt: e.aliases[0]!,
      place_name: e.aliases[0]!,
      branch_hint: null,
      city: null,
      country_code: null,
      search_query: null,
      category: "place",
      start_time: e.start_time ?? null,
      end_time: null,
      time_is_approximate: false,
      fixed_suspected: e.fixed ?? false,
      fixed_reason: null,
      confidence: "high",
      needs_confirmation: [...(e.flags ?? [])],
    });
    days.set(e.date, day);
  }
  return { days: [...days.values()], city_candidates: [], warnings: [] };
}

interface CaseRun {
  id: string;
  status: "parsed" | "failed" | "error";
  score?: CaseScore;
  latencyMs: number;
  usage?: { input_tokens: number; output_tokens: number };
  output?: unknown;
  error?: string;
}

async function runCase(client: Anthropic | null, c: EvalCase, options: ParseOptions): Promise<CaseRun> {
  const started = Date.now();
  if (!client) {
    return { id: c.id, status: "parsed", score: scoreCase(c, draftFromExpectations(c)), latencyMs: 0 };
  }
  try {
    const outcome = await parseItinerary(client, c, options);
    const latencyMs = Date.now() - started;
    if (outcome.status === "failed") {
      return { id: c.id, status: "failed", latencyMs, output: outcome };
    }
    return {
      id: c.id,
      status: "parsed",
      score: scoreCase(c, outcome.result),
      latencyMs,
      usage: outcome.usage,
      output: { result: outcome.result, issues: outcome.issues, model: outcome.model },
    };
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) throw err;
    const message = err instanceof Anthropic.APIError ? `${err.status} ${err.message}` : String(err);
    return { id: c.id, status: "error", latencyMs: Date.now() - started, error: message };
  }
}

async function main(): Promise<void> {
  const cases = args.only ? CASES.filter((c) => args.only!.split(",").includes(c.id)) : CASES;
  const client = args["dry-run"] ? null : new Anthropic();
  const options: ParseOptions = {
    model: args.model,
    ...(args.effort ? { effort: args.effort as ParseOptions["effort"] } : {}),
  };

  const runs: CaseRun[] = [];
  const queue = [...cases];
  const workers = Array.from({ length: Number(args.concurrency) }, async () => {
    for (let c = queue.shift(); c; c = queue.shift()) {
      const run = await runCase(client, c, options);
      runs.push(run);
      const failures = run.score?.failures.length ?? 0;
      console.log(`${run.status === "parsed" ? (failures ? "WARN" : "PASS") : "FAIL"} ${c.id}` +
        (run.status !== "parsed" ? ` (${run.status}${run.error ? `: ${run.error}` : ""})` : failures ? ` (${failures} issues)` : ""));
    }
  });
  await Promise.all(workers);
  runs.sort((a, b) => a.id.localeCompare(b.id));

  const scored = runs.flatMap((r) => (r.score ? [r.score] : []));
  const totals = sumScores(scored);
  const parsed = runs.filter((r) => r.status === "parsed").length;
  const latencies = runs.filter((r) => r.usage).map((r) => r.latencyMs).sort((a, b) => a - b);
  const inTok = runs.reduce((n, r) => n + (r.usage?.input_tokens ?? 0), 0);
  const outTok = runs.reduce((n, r) => n + (r.usage?.output_tokens ?? 0), 0);

  console.log("\n== Summary ==");
  console.log(`mode              ${args["dry-run"] ? "dry-run (scorer self-check)" : `${options.model}${options.effort ? ` effort=${options.effort}` : ""}`}`);
  console.log(`valid output      ${pct([parsed, runs.length])}`);
  console.log(`stops found       ${pct(totals.stopRecall)}`);
  console.log(`date correct      ${pct(totals.date)}`);
  console.log(`start time        ${pct(totals.time)}`);
  console.log(`fixed flag        ${pct(totals.fixed)}`);
  console.log(`required flags    ${pct(totals.flags)}   <- includes ambiguous_branch (AC-01)`);
  console.log(`no wrong flags    ${pct(totals.notFlags)}`);
  console.log(`non-stops kept out ${pct(totals.mustNotInclude)}`);
  console.log(`extra stops       ${totals.extraStops} (not in expectations; review manually)`);
  if (latencies.length) {
    console.log(`latency p50/p90   ${latencies[Math.floor(latencies.length * 0.5)]}ms / ${latencies[Math.floor(latencies.length * 0.9)]}ms`);
    console.log(`tokens in/out     ${inTok} / ${outTok}`);
  }

  for (const s of scored.filter((s) => s.failures.length)) {
    console.log(`\n${s.id}\n  - ${s.failures.join("\n  - ")}`);
  }

  if (!args["dry-run"]) {
    const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "results");
    mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
    writeFileSync(file, JSON.stringify({ options, totals, runs }, null, 2));
    console.log(`\nSaved ${file}`);
  }

  // The dry run scores drafts built from the expectations, so anything short of a
  // clean pass means the scorer (or the eval set) is broken: fail CI.
  if (args["dry-run"]) {
    const broken = runs.filter((r) => r.status !== "parsed" || (r.score?.failures.length ?? 0) > 0);
    if (broken.length > 0 || totals.extraStops > 0) {
      console.error(`\nScorer self-check failed: ${broken.map((r) => r.id).join(", ") || `${totals.extraStops} extra stops`}`);
      process.exitCode = 1;
    }
  }
}

await main();
