// Scores a parse draft against a case's partial expectations.

import type { ParseResult, ParsedStop } from "../src/schema.ts";
import type { EvalCase, ExpectedStop } from "./cases.ts";

export function normalize(s: string): string {
  return s.toLowerCase().normalize("NFKC").replace(/[\s・·\-_'’.]/g, "");
}

interface FlatStop {
  date: string | null;
  stop: ParsedStop;
}

function flatten(result: ParseResult): FlatStop[] {
  return result.days.flatMap((d) => d.stops.map((stop) => ({ date: d.date, stop })));
}

function matchesAlias(stop: ParsedStop, aliases: string[]): boolean {
  const hay = [stop.place_name, stop.search_query, stop.source_excerpt]
    .filter((x): x is string => !!x)
    .map(normalize);
  return aliases.some((a) => hay.some((h) => h.includes(normalize(a))));
}

// Counts: [passed, total] per check, so they can be summed across cases.
export interface CaseScore {
  id: string;
  stopRecall: [number, number];
  date: [number, number];
  time: [number, number];
  fixed: [number, number];
  flags: [number, number];
  notFlags: [number, number];
  mustNotInclude: [number, number];
  extraStops: number;
  failures: string[];
}

export function scoreCase(c: EvalCase, result: ParseResult): CaseScore {
  const predicted = flatten(result);
  const used = new Set<number>();
  const score: CaseScore = {
    id: c.id,
    stopRecall: [0, c.expected.length],
    date: [0, 0],
    time: [0, 0],
    fixed: [0, 0],
    flags: [0, 0],
    notFlags: [0, 0],
    mustNotInclude: [0, c.mustNotInclude?.length ?? 0],
    extraStops: 0,
    failures: [],
  };

  const findMatch = (e: ExpectedStop): number => {
    // Prefer a stop on the expected date, so duplicates on different days pair up.
    const candidates = predicted
      .map((p, i) => ({ p, i }))
      .filter(({ p, i }) => !used.has(i) && matchesAlias(p.stop, e.aliases));
    const sameDay = candidates.find(({ p }) => p.date === e.date);
    return (sameDay ?? candidates[0])?.i ?? -1;
  };

  for (const e of c.expected) {
    const label = e.aliases[0];
    const idx = findMatch(e);
    if (idx < 0) {
      score.failures.push(`missing stop "${label}"`);
      continue;
    }
    used.add(idx);
    score.stopRecall[0]++;
    const { date, stop } = predicted[idx]!;

    score.date[1]++;
    if (date === e.date) score.date[0]++;
    else score.failures.push(`"${label}" date ${date} != ${e.date}`);

    if (e.start_time !== undefined) {
      score.time[1]++;
      if (stop.start_time === e.start_time) score.time[0]++;
      else score.failures.push(`"${label}" time ${stop.start_time} != ${e.start_time}`);
    }

    if (e.fixed !== undefined) {
      score.fixed[1]++;
      if (stop.fixed_suspected === e.fixed) score.fixed[0]++;
      else score.failures.push(`"${label}" fixed ${stop.fixed_suspected} != ${e.fixed}`);
    }

    for (const f of e.flags ?? []) {
      score.flags[1]++;
      if (stop.needs_confirmation.includes(f)) score.flags[0]++;
      else score.failures.push(`"${label}" missing flag ${f}`);
    }
    for (const f of e.not_flags ?? []) {
      score.notFlags[1]++;
      if (!stop.needs_confirmation.includes(f)) score.notFlags[0]++;
      else score.failures.push(`"${label}" wrongly flagged ${f}`);
    }
  }

  for (const term of c.mustNotInclude ?? []) {
    const leaked = predicted.some(({ stop }) => stop.place_name && normalize(stop.place_name).includes(normalize(term)));
    if (!leaked) score.mustNotInclude[0]++;
    else score.failures.push(`non-stop "${term}" became a stop`);
  }

  score.extraStops = predicted.length - used.size;
  return score;
}

export type Totals = Omit<CaseScore, "id" | "failures" | "extraStops"> & { extraStops: number };

export function sumScores(scores: CaseScore[]): Totals {
  const keys = ["stopRecall", "date", "time", "fixed", "flags", "notFlags", "mustNotInclude"] as const;
  const totals = Object.fromEntries(keys.map((k) => [k, [0, 0]])) as unknown as Totals;
  totals.extraStops = 0;
  for (const s of scores) {
    for (const k of keys) {
      totals[k][0] += s[k][0];
      totals[k][1] += s[k][1];
    }
    totals.extraStops += s.extraStops;
  }
  return totals;
}

export function pct([pass, total]: [number, number]): string {
  return total === 0 ? "n/a" : `${((100 * pass) / total).toFixed(1)}% (${pass}/${total})`;
}
