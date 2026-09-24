import type { AssistantAnswer } from "../src/schema.ts";
import type { EvalCase } from "./cases.ts";

export interface CaseScore {
  id: string;
  cannotDetermineOK: boolean;
  citationsOK: boolean;
  proposalOK: boolean;
  phrasingOK: boolean;
  pass: boolean;
  notes: string[];
}

export function scoreCase(c: EvalCase, a: AssistantAnswer): CaseScore {
  const notes: string[] = [];
  const cannotDetermineOK = a.cannot_determine === c.expect.cannot_determine;
  if (!cannotDetermineOK) notes.push(`cannot_determine=${a.cannot_determine}`);

  const cited = new Set(a.citations.map((x) => x.id));
  const missing = (c.expect.must_cite ?? []).filter((id) => !cited.has(id));
  const citationsOK = missing.length === 0;
  if (!citationsOK) notes.push(`missing citations ${missing.join(",")}`);

  let proposalOK = true;
  if (c.expect.proposal === "none") {
    proposalOK = a.proposal === null;
  } else if (c.expect.proposal) {
    proposalOK = a.proposal?.day_id === c.expect.proposal.day_id && a.proposal?.saved_id === c.expect.proposal.saved_id;
  }
  if (!proposalOK) notes.push(`proposal=${JSON.stringify(a.proposal)}`);

  const bad = (c.expect.must_not_say ?? []).filter((p) => a.answer.includes(p));
  const phrasingOK = bad.length === 0;
  if (!phrasingOK) notes.push(`says ${bad.join(",")}`);

  return { id: c.id, cannotDetermineOK, citationsOK, proposalOK, phrasingOK,
           pass: cannotDetermineOK && citationsOK && proposalOK && phrasingOK, notes };
}
