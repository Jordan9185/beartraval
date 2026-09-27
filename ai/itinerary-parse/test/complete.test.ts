import assert from "node:assert/strict";
import test from "node:test";
import type Anthropic from "@anthropic-ai/sdk";
import { createItineraryDraft, mergeSuggestedDays, missingItineraryDays } from "../src/complete.ts";
import { buildSuggestedDraft, SuggestionError } from "../src/suggest.ts";
import type { ParseInput, ParseResult } from "../src/schema.ts";

const input: ParseInput = { tripName: "東京五日", rawText: "幫我規劃五日旅遊",
  tripStart: "2026-09-27", tripEnd: "2026-10-01", timeZone: "Asia/Tokyo" };
const source = { url: "https://example.com/asakusa", title: "浅草寺", cited_text: "東京的浅草寺、上野公園、明治神宮、新宿御苑、銀座" };
const suggestion = { day_index: 2, name: "淺草寺", local_name: "浅草寺", city: "Tokyo", country_code: "JP",
  category: "place", reason: "公開來源的景點", source_url: source.url };
const usage = { input_tokens: 1, output_tokens: 1 };
const calls: Array<Record<string, any>> = [];
function client(draft?: ParseResult, hasSources = true): Anthropic {
  // 合成 SDK 回應僅驗證上下文傳遞與合併，不代表真模型品質。
  return { messages: { create: async (request: Record<string, any>) => {
    calls.push(request);
    return { model: "fixture", usage, content: hasSources ? [{ type: "text", text: "浅草寺",
      citations: [{ type: "web_search_result_location", ...source }] }] : [] };
  } }, beta: { messages: {
    parse: async (request: Record<string, any>) => { calls.push(request); return {
      model: "fixture", usage, parsed_output: { stops: (JSON.parse(request.messages[0].content).days_to_suggest ?? [1, 2, 3, 4, 5]).map((day: number) => ({ ...suggestion, day_index: day, name: ["上野公園", "浅草寺", "明治神宮", "新宿御苑", "銀座"][day - 1], local_name: null })) } }; },
    stream: () => ({ on: () => {}, finalMessage: async () => ({ model: "fixture", usage,
      stop_reason: "end_turn", parsed_output: draft }) }),
  } } } as unknown as Anthropic;
}

function original(): ParseResult {
  const result = buildSuggestedDraft([{ ...suggestion, day_index: 1, name: "晴空塔", local_name: "東京スカイツリー",
    category: "place", source_url: null }], [input.tripStart], false);
  const stop = result.days[0]!.stops[0]!;
  stop.source_excerpt = "Day 1 10:00 晴空塔訂位";
  stop.place_name = "晴空塔";
  stop.start_time = "10:00";
  stop.fixed_suspected = true;
  stop.fixed_reason = "訂位";
  return result;
}

test("東京放在名稱、原文只有五日需求時，搜尋與排程均取得名稱且原文不被改寫", async () => {
  calls.length = 0;
  const result = await createItineraryDraft(client(), input);
  assert.equal(result.status, "parsed");
  assert.equal(calls.length, 2);
  for (const call of calls) {
    const sent = JSON.parse(call.messages[0].content);
    assert.equal(sent.trip_name, "東京五日");
    assert.equal(sent.request, "幫我規劃五日旅遊");
  }
  if (result.status === "parsed") {
    assert.equal(result.result.days.length, 5);
    assert.ok(result.result.days.every((day) => day.stops.length > 0));
  }
});

test("部分行程先保留指定日期與固定時間，再只補未提供的日期", async () => {
  const draft = original();
  const partial = { ...input, rawText: "Day 1 10:00 晴空塔訂位，其他幫我安排" };
  assert.deepEqual(missingItineraryDays(partial, draft), [2, 3, 4, 5]);
  calls.length = 0;
  const result = await createItineraryDraft(client(draft), partial);
  assert.equal(result.status, "parsed");
  if (result.status !== "parsed") return;
  const first = result.result.days.find((day) => day.date === input.tripStart)!;
  assert.deepEqual(first.stops, draft.days[0]!.stops);
  assert.ok(result.result.days.some((day) => day.date === "2026-09-28" && day.stops[0]?.place_name === "浅草寺"));
  assert.deepEqual(JSON.parse(calls[1]!.messages[0].content).days_to_suggest, [2, 3, 4, 5]);
});

test("完整行程與明確留白不呼叫補排行程", async () => {
  const complete = { ...input, tripEnd: input.tripStart, rawText: "Day 1 10:00 晴空塔訂位" };
  calls.length = 0;
  const result = await createItineraryDraft(client(original()), complete);
  assert.equal(result.status, "parsed");
  assert.equal(calls.length, 0);
  assert.deepEqual(missingItineraryDays({ ...input, rawText: "Day 1 晴空塔，其餘自由活動" }, original()), []);
});

test("沒有可核對來源不是 JSON 格式錯誤，且不能丟掉已解析的部分行程", async () => {
  await assert.rejects(createItineraryDraft(client(undefined, false), input),
    (error: unknown) => error instanceof SuggestionError && error.reason === "no_verified_suggestions");
  const partial = await createItineraryDraft(client(original(), false), { ...input, rawText: "Day 1 10:00 晴空塔訂位" });
  assert.equal(partial.status, "parsed");
  if (partial.status === "parsed") {
    assert.deepEqual(partial.result.days[0]!.stops, original().days[0]!.stops);
    assert.ok(partial.result.warnings.some((warning) => warning.includes("暫時未能完成")));
  }
});

test("補排回傳不能覆蓋原日期或把原指定點搬去另一日", () => {
  const draft = original();
  const replacement = structuredClone(draft);
  replacement.days.push({ ...structuredClone(draft.days[0]!), date: "2026-09-28" });
  replacement.days[0]!.stops[0]!.start_time = "15:00";
  const merged = mergeSuggestedDays(draft, replacement, [input.tripStart, "2026-09-28"]);
  assert.deepEqual(merged.days, draft.days);
});

test("補入較早日期後，原本的時間問題仍指向原站點", async () => {
  const draft = original();
  draft.days[0]!.date = "2026-09-29";
  draft.days[0]!.stops[0]!.start_time = "25:00";
  const result = await createItineraryDraft(client(draft), { ...input, rawText: "Day 3 25:00 晴空塔訂位" });
  assert.equal(result.status, "parsed");
  if (result.status !== "parsed") return;
  assert.equal(result.result.days[2]?.date, "2026-09-29");
  assert.ok(result.issues.some((issue) => issue.path === "days[2].stops[0].start_time"));
  assert.equal(result.result.days[2]?.stops[0]?.start_time, null);
});

test("明確要求規劃時，保留原站與 Fixed，再為已給目的地的日期補建議", async () => {
  const draft = original();
  // 未固定的第二天只寫城市，仍需補上具名景點。
  draft.days.push({ date: "2026-09-28", day_label: "第二天", stops: [{ ...draft.days[0]!.stops[0]!,
    place_name: "東京", search_query: "Tokyo", start_time: null, fixed_suspected: false, fixed_reason: null }] });
  calls.length = 0;
  const result = await createItineraryDraft(client(draft), { ...input, rawText: "Day 1 10:00 晴空塔訂位，第二天東京，幫我安排行程" });
  assert.equal(result.status, "parsed");
  if (result.status !== "parsed") return;
  assert.equal(result.result.days.length, 5);
  assert.deepEqual(result.result.days[0]!.stops[0], draft.days[0]!.stops[0]);
  assert.deepEqual(result.result.days[1]!.stops[0], draft.days[1]!.stops[0]);
  assert.ok(result.result.days[1]!.stops.length > 1);
  assert.deepEqual(JSON.parse(calls[1]!.messages[0].content).days_to_suggest, [1, 2, 3, 4, 5]);
});

test("日韓七日保留前三天骨架，兩國景點皆可核對，不被單一國家濾掉", async () => {
  const dates = Array.from({ length: 7 }, (_, i) => `2026-10-${23 + i}`);
  const names = ["景福宮", "北村韓屋村", "平和記念公園", "廣島城", "縮景園", "嚴島神社", "尾道"];
  const originalDraft: ParseResult = { city_candidates: ["首爾", "廣島"], warnings: [], days: dates.slice(0, 3).map((date, i) => ({ date,
    day_label: `第 ${i + 1} 天`, stops: [{ ...original().days[0]!.stops[0]!, place_name: i < 2 ? "首爾" : "廣島",
      search_query: i < 2 ? "서울" : "広島", city: i < 2 ? "Seoul" : "Hiroshima", country_code: i < 2 ? "KR" : "JP",
      source_excerpt: i < 2 ? "前三天要去首爾" : "第三天飛日本廣島", start_time: null, fixed_suspected: false, fixed_reason: null }] })) };
  const fixture = client(originalDraft);
  fixture.messages.create = (async () => ({ model: "fixture", usage, content: [{ type: "text", text: names.join("、"), citations: [{
    type: "web_search_result_location", ...source, title: "日韓景點", cited_text: names.join("、") }] }] })) as any;
  fixture.beta.messages.parse = (async () => ({ model: "fixture", usage, parsed_output: { stops: names.map((name, i) => ({ ...suggestion,
    day_index: i + 1, name, local_name: null, city: i < 2 ? "首爾" : "廣島", country_code: i < 2 ? "KR" : "JP" })) } })) as any;
  const result = await createItineraryDraft(fixture, { tripName: "日韓七日遊", rawText: "我前三天要去首爾 第三天飛日本廣島 幫我安排行程",
    tripStart: dates[0]!, tripEnd: dates[6]!, timeZone: "Asia/Seoul" });
  assert.equal(result.status, "parsed");
  if (result.status !== "parsed") return;
  assert.deepEqual(result.result.days.map(day => day.date), dates);
  assert.ok(result.result.days.every(day => day.stops.some(stop => names.includes(stop.place_name ?? ""))));
  assert.equal(result.result.days[0]!.stops[1]!.country_code, "KR");
  assert.equal(result.result.days[6]!.stops[0]!.country_code, "JP");
});
