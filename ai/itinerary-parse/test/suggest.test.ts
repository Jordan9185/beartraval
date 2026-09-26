import assert from "node:assert/strict";
import test from "node:test";
import { buildSuggestedDraft, explicitWishPlaces, requestedDays, templateRequest, verifiedTemplateStops } from "../src/suggest.ts";

test("只有目的地與天數的短句走建議樣板，逐日行程保持原文解析", () => {
  assert.equal(templateRequest("我要去 日本東京五天旅遊"), true);
  assert.equal(templateRequest("想安排東京 5 天行程"), true);
  assert.equal(templateRequest("東京十五天旅遊"), false);
  assert.equal(requestedDays("東京五天"), 5);
  assert.equal(templateRequest("東京五天行程\nDay 1 淺草寺"), false);
  assert.equal(templateRequest("想去淺草寺、上野、迪士尼", 5), true);
  assert.equal(templateRequest("週一淺草寺、週二上野", 5), false);
  assert.deepEqual(explicitWishPlaces("我想去淺草寺、上野、迪士尼"), ["淺草寺", "上野", "迪士尼"]);
});

test("建議景點必須有支持名稱的網頁引用，且不能超出旅程天數", () => {
  const source = { url: "https://example.com/tokyo", title: "浅草寺 Tokyo", citedText: "浅草寺位於東京淺草" };
  const stops = [
    { day_index: 1, name: "淺草寺", local_name: "浅草寺", city: "Tokyo", country_code: "JP",
      category: "place", reason: "東京景點", source_url: source.url },
    { day_index: 2, name: "虛構景點", local_name: null, city: "Tokyo", country_code: "JP",
      category: "place", reason: "模型猜測", source_url: source.url },
    { day_index: 6, name: "浅草寺", local_name: null, city: "Tokyo", country_code: "JP",
      category: "place", reason: "超出日期", source_url: source.url },
  ];
  assert.deepEqual(verifiedTemplateStops({ stops }, [source], 5).map((stop) => stop.local_name), ["浅草寺"]);
});

test("無網頁來源只能保留使用者原文指定的地點", () => {
  const input = { stops: [
    { day_index: 1, name: "淺草寺", local_name: "浅草寺", city: "Tokyo", country_code: "JP",
      category: "place", reason: "使用者指定", source_url: null },
    { day_index: 2, name: "虛構神社", local_name: null, city: "Tokyo", country_code: "JP",
      category: "place", reason: "模型新增", source_url: null },
  ] };
  assert.deepEqual(verifiedTemplateStops(input, [], 5, "JP", "我想去淺草寺").map((stop) => stop.name), ["淺草寺"]);
  const retained = verifiedTemplateStops(input, [], 5, "JP", "我想去淺草寺");
  const draft = buildSuggestedDraft(retained, ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"], false);
  assert.equal(draft.days.length, 5);
  assert.equal(draft.days[0]?.date, "2026-10-01");
  assert.equal(draft.days[0]?.stops[0]?.place_name, "浅草寺");
  assert.equal(draft.days[0]?.stops[0]?.confidence, "medium");
  assert.equal(draft.days[1]?.stops.length, 0);
});
