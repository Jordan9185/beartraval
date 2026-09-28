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
    if (result.cannot_determine || saved?.ai_suppressed) {
      issues.push({ path: "proposal", issue: "proposal with cannot_determine" });
      result.proposal = null;
    } else if (!saved || !dayOK) {
      issues.push({ path: "proposal", issue: "proposal refers to unknown day or saved place" });
      result.proposal = null;
    } else if (!saved.place_confirmed && !saved.address?.trim()) {
      issues.push({ path: "proposal", issue: "proposal for an unconfirmed place" });
      result.proposal = null;
    }
  }

  result.arrangements = (result.arrangements ?? []).filter((action, index, actions) => {
    if (action.start_time && (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(action.start_time) || action.kind === "stop_remove")) return false;
    if (result.cannot_determine || !context.days.some((day) => day.id === action.day_id)
      || actions.findIndex((a) => a.kind === action.kind && a.item_id === action.item_id) !== index) return false;
    if (action.kind === "stop_move" || action.kind === "stop_remove") {
      const source = context.days.find((day) => day.stops.some((stop) => stop.id === action.item_id));
      const stop = source?.stops.find((stop) => stop.id === action.item_id);
      return !!stop && !stop.fixed && (action.kind !== "stop_remove" || source?.id === action.day_id)
        && actions.filter((a) => (a.kind === "stop_move" || a.kind === "stop_remove") && a.item_id === action.item_id).length === 1;
    }
    if (action.kind === "saved") {
      const entry = context.saved.find((s) => s.id === action.item_id);
      return !!entry && !entry.ai_suppressed && (!!entry.place_confirmed || !!entry.address?.trim());
    }
    const item = context.shopping.find((s) => s.id === action.item_id);
    return item?.status === "unscheduled" && item.purchase_timing !== "before_trip" && !item.ai_suppressed && (item.store_candidates?.filter((s) => s.source_url === action.source_url).length === 1)
      && hasSharedArea(action.matched_area, item.store_candidates?.find((s) => s.source_url === action.source_url),
        context.days.find((d) => d.id === action.day_id)?.stops.find((s) => s.id === action.anchor_stop_id));
  });
  if (result.shopping_proposal) {
    const proposal = result.shopping_proposal;
    const item = context.shopping.find((i) => i.id === proposal.item_id);
    const day = context.days.find((d) => d.id === proposal.day_id);
    if (result.cannot_determine || item?.status !== "unscheduled" || item.purchase_timing === "before_trip" || item.ai_suppressed || !day?.stops.some((s) => s.id === proposal.anchor_stop_id)
      || item.store_candidates?.filter((c) => c.source_url === proposal.source_url).length !== 1
      || !hasSharedArea(proposal.matched_area, item.store_candidates?.find((c) => c.source_url === proposal.source_url),
        day?.stops.find((s) => s.id === proposal.anchor_stop_id))) {
      issues.push({ path: "shopping_proposal", issue: "no existing itinerary anchor or verified candidate" });
      result.shopping_proposal = null;
    }
  }
  if (result.answer.trim().length === 0) {
    issues.push({ path: "answer", issue: "empty answer" });
    result.cannot_determine = true;
    result.answer = "無法從目前的行程資料判斷。";
  }
  return { answer: result, issues };
}

// 採買必須有兩端資料共同支持的區域名稱，不能拿任意既有站點當作順路證明。
// 僅城市／國家相同不夠；資料不足就保留待買，仍可另外提出手動修改行程。
export function hasSharedArea(area: string | null | undefined, store: { name: string; address?: string | null } | undefined,
  stop: { label: string; address?: string | null } | undefined): boolean {
  const normalize = (text: string) => text.normalize("NFKC").toLowerCase().replace(/\s+/gu, "");
  const key = normalize(area ?? "");
  const broad = ["首爾", "首尔", "seoul", "서울", "서울특별시", "韓國", "韩国", "대한민국", "korea", "中國", "中国", "china", "日本", "japan", "東京", "东京", "tokyo", "大阪", "osaka", "北京", "上海", "busan", "부산", "釜山"];
  return key.length >= 2 && !broad.includes(key) && !!store && !!stop
    && normalize(store.name + " " + (store.address ?? "")).includes(key)
    && normalize(stop.label + " " + (stop.address ?? "")).includes(key);
}
