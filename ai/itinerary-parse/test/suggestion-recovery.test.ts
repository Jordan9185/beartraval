import assert from "node:assert/strict";
import test from "node:test";
import type Anthropic from "@anthropic-ai/sdk";
import { citedTemplateSources, suggestItinerary, SuggestionError, verifiedTemplateStops } from "../src/suggest.ts";

const url = "https://example.com/places";
const usage = { input_tokens: 2, output_tokens: 3 };
const stop = (day: number, name: string, source_url = url) => ({ day_index: day, name, local_name: null,
  city: "東京", country_code: "JP", category: "place", reason: "公開資料列名", source_url });
const message = (content: unknown[], stop_reason = "end_turn") => ({ model: "fixture", usage, content, stop_reason }) as Anthropic.Message;
const citation = (text: string) => ({ type: "text", text: "模型文字不能當證據", citations: [
  { type: "web_search_result_location", url, title: "東京景點", cited_text: text }] });
const input = { tripName: "東京二日", rawText: "幫我規劃兩日旅遊", tripStart: "2026-09-27",
  tripEnd: "2026-09-28", timeZone: "Asia/Tokyo" };

test("同網址的多段引用不互相覆蓋；搜尋標題可核對但模型摘要不可", () => {
  const sources = citedTemplateSources(message([citation("浅草寺"), citation("上野公園"), citation(""),
    { type: "web_search_tool_result", content: [{ type: "web_search_result", url: "https://example.com/museum", title: "国立科学博物館" }] },
    { type: "text", text: "虛構景點", citations: [] }]));
  assert.ok(sources[0]?.citedText.includes("浅草寺"));
  assert.ok(sources[0]?.citedText.includes("上野公園"));
  assert.equal(sources.length, 2);
  const raw = { stops: [stop(1, "浅草寺", url + "/JP"), stop(2, "国立科学博物館", url), stop(2, "虛構景點")] };
  const retained = verifiedTemplateStops(raw, sources, 2, "JP");
  assert.deepEqual(retained.map((item) => item.source_url), [url, "https://example.com/museum"]);
  assert.equal(raw.stops[0]?.source_url, url + "/JP");
});

function fake(search: Anthropic.Message[], outputs: unknown[], requests: any[]): Anthropic {
  return { messages: { create: async (request: any) => { requests.push(request); return search.shift(); } },
    beta: { messages: { parse: async (request: any) => { requests.push(request);
      return { model: "fixture", usage, parsed_output: outputs.shift() }; } } } } as unknown as Anthropic;
}

test("搜尋 pause_turn 延續完整內容；缺日補排只補空日並累計用量", async () => {
  const requests: any[] = [];
  const paused = message([{ type: "text", text: "搜尋進行中", citations: [] }], "pause_turn");
  const result = await suggestItinerary(fake([paused, message([citation("浅草寺、上野公園")])],
    [{ stops: [stop(1, "浅草寺"), stop(2, "虛構景點")] }, { stops: [stop(2, "上野公園")] }], requests), input);
  assert.deepEqual(requests[1].messages[1].content, paused.content);
  assert.deepEqual(JSON.parse(requests[3].messages[0].content).days_to_suggest, [2]);
  assert.deepEqual(result?.result.days.map((day) => day.stops.length), [1, 1]);
  assert.deepEqual(result?.usage, { input_tokens: 8, output_tokens: 12 });
});

test("重複景點不能湊天數，有限補排仍缺日時明確失敗", async () => {
  const requests: any[] = [];
  await assert.rejects(suggestItinerary(fake([message([citation("浅草寺")])],
    [{ stops: [stop(1, "浅草寺"), stop(2, "浅草寺")] }, { stops: [stop(2, "浅草寺")] }], requests), input),
    (error: unknown) => error instanceof SuggestionError && error.reason === "incomplete_suggestions");
  assert.equal(requests.length, 3);
});

test("HTTP 成功但搜尋工具不可用時，不把錯誤或無引用摘要當景點", async () => {
  await assert.rejects(suggestItinerary(fake([message([
    { type: "web_search_tool_result", content: { type: "web_search_tool_result_error", error_code: "unavailable" } },
    { type: "text", text: "推薦浅草寺", citations: [] }])], [], []), input),
    (error: unknown) => error instanceof SuggestionError && error.reason === "no_verified_suggestions");
});

test("多個日期缺少可核對來源時有限補查，第二輪取得拒收項目而非重複同一提示", async () => {
  const requests: any[] = [];
  const result = await suggestItinerary(fake([
    message([citation("浅草寺")]), message([citation("上野公園、明治神宮")]),
  ], [{ stops: [stop(1, "浅草寺"), stop(2, "沒有來源的點")] },
      { stops: [stop(2, "上野公園"), stop(3, "明治神宮")] }], requests),
    { ...input, tripName: "東京三日", tripEnd: "2026-09-29", rawText: "幫我規劃三日旅遊" });
  assert.deepEqual(result?.result.days.map(day => day.stops.length), [1, 1, 1]);
  assert.equal(requests.length, 4);
  assert.deepEqual(JSON.parse(requests[2].messages[0].content).days_to_suggest, [2, 3]);
  assert.equal(JSON.parse(requests[3].messages[0].content).rejected_stops[1].name, "沒有來源的點");
});
