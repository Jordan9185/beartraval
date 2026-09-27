import type Anthropic from "@anthropic-ai/sdk";
import { tripCalendar } from "./prompt.ts";
import { parseItinerary, type ParseOptions, type ParseOutcome } from "./parse.ts";
import { suggestItinerary, templateRequest } from "./suggest.ts";
import type { ParseInput, ParseResult, ParsedStop } from "./schema.ts";

/// 完整原文不改安排；部分行程先解析並鎖住原內容，再為未提到的日期補建議。
export function missingItineraryDays(input: ParseInput, draft: ParseResult): number[] {
  if (/其[餘余他].{0,8}(?:自由活動|留白|不安排)|(?:不要|不必|不用)(?:補|新增|安排)|只(?:需|要)(?:整理|解析)/u.test(input.rawText)) return [];
  const dates = tripCalendar(input.tripStart, input.tripEnd).map((entry) => entry.slice(0, 10));
  if (dates.length > 14) return [];
  const mentioned = new Set(draft.days.map((day) => day.date));
  return dates.flatMap((date, index) => mentioned.has(date) ? [] : [index + 1]);
}

export function mergeSuggestedDays(original: ParseResult, suggestion: ParseResult, dates: string[]): ParseResult {
  const result = structuredClone(original);
  const nameKey = (value: string) => value.normalize("NFKC").replace(/\s+/g, "").toLocaleLowerCase();
  const keys = (stop: ParsedStop) => [stop.place_name, stop.search_query].filter((name): name is string => !!name).map(nameKey);
  const seen = new Set(original.days.flatMap((day) => day.stops.flatMap(keys)));
  for (const date of dates) {
    if (result.days.some((day) => day.date === date)) continue;
    const day = suggestion.days.find((candidate) => candidate.date === date);
    if (!day) continue;
    const stops = day.stops.filter((stop) => {
      const names = keys(stop);
      if (names.some((name) => seen.has(name))) return false;
      names.forEach((name) => seen.add(name));
      return true;
    });
    if (stops.length) result.days.push({ ...structuredClone(day), stops: structuredClone(stops) });
  }
  result.days.sort((a, b) => (a.date ?? "9999").localeCompare(b.date ?? "9999"));
  result.city_candidates = [...new Set([...original.city_candidates, ...suggestion.city_candidates])];
  result.warnings = [...new Set([...original.warnings, ...suggestion.warnings,
    "已保留原文指定的日期、順序與時間；未提供安排的日期另補 AI 建議，確認後才建立旅程。"])];
  return result;
}

export async function createItineraryDraft(client: Anthropic, input: ParseInput, options: ParseOptions = {}): Promise<ParseOutcome> {
  const dates = tripCalendar(input.tripStart, input.tripEnd).map((entry) => entry.slice(0, 10));
  if (templateRequest(input.rawText, dates.length)) {
    options.onProgress?.({ stage: "reading", days: 0, stops: 0, last_place: null });
    const suggested = await suggestItinerary(client, input, options.model);
    return suggested ? { status: "parsed", ...suggested, issues: [] } : { status: "failed", reason: "invalid_output" };
  }
  const parsed = await parseItinerary(client, input, options);
  if (parsed.status !== "parsed") return parsed;
  const missing = missingItineraryDays(input, parsed.result);
  if (!missing.length) return parsed;
  try {
    const suggested = await suggestItinerary(client, input, options.model, { existingDraft: parsed.result, dayIndexes: missing });
    if (suggested) {
      const result = mergeSuggestedDays(parsed.result, suggested.result, missing.map((index) => dates[index - 1]!));
      // 補入較早日期後，既有檢查問題仍需指向原來那一天，而不是新插入的日期。
      const used = new Set<number>();
      const dayIndexes = parsed.result.days.map((original) => {
        const index = result.days.findIndex((day, index) => !used.has(index) && JSON.stringify(day) === JSON.stringify(original));
        used.add(index);
        return index;
      });
      const issues = parsed.issues.map((issue) => ({ ...issue, path: issue.path.replace(/^days\[(\d+)\]/u,
        (path, index: string) => dayIndexes[Number(index)]! >= 0 ? `days[${dayIndexes[Number(index)]}]` : path) }));
      return { ...parsed, result, issues, model: suggested.model,
        usage: { input_tokens: parsed.usage.input_tokens + suggested.usage.input_tokens,
          output_tokens: parsed.usage.output_tokens + suggested.usage.output_tokens } };
    }
  } catch { /* 補查失敗仍保留已成功解析的安排，不能把整份原行程當失敗。 */ }
  parsed.result.warnings.push("已保留你提供的安排，但其餘日期的建議暫時未能完成；可先核對現有草稿。");
  return parsed;
}
