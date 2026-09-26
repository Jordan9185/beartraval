import assert from "node:assert/strict";
import test from "node:test";
import { validateResult } from "../src/organize.ts";

test("四間明確店家各自歸檔，沒有來源錨點的項目被丟棄", () => {
  const text = "聖水洞：A咖啡、B麵包、C書店、D選物。";
  const items = ["A咖啡", "B麵包", "C書店", "D選物"].map((name) => ({
    kind: "place", display_name: name, source_span: name, origin_type: "explicit", confidence: "high", day_index: null,
    store_hint: null, store_evidence: null,
  }));
  const result = validateResult({ title: null, rawText: text, imageBase64: [] }, {
    content_kind: "recommendations", items: [...items, { ...items[0], display_name: "虛構店", source_span: "虛構店" }], template_days: [],
  });
  assert.equal(result.items.length, 4);
  assert.ok(result.items.every((item) => item.auto_archive));
});

test("明確圖片商品可自動歸檔，歧義分店只保留候選", () => {
  const result = validateResult({ title: null, rawText: "A咖啡可能是明洞或弘大分店", imageBase64: ["jpeg"] }, {
    content_kind: "mixed", items: [
      { kind: "place", display_name: "A咖啡", source_span: "A咖啡可能是明洞或弘大分店", origin_type: "explicit", confidence: "high", day_index: null, store_hint: null, store_evidence: null },
      { kind: "product", display_name: "ReFa", source_span: "image:1", origin_type: "explicit", confidence: "high", day_index: null, store_hint: null, store_evidence: null },
    ], template_days: [],
  });
  assert.equal(result.items[0]?.auto_archive, false);
  assert.equal(result.items[1]?.auto_archive, true);
});

test("圖片中的模糊料理線索不會自動當成已確認餐廳", () => {
  const result = validateResult({ title: null, rawText: "", imageBase64: ["jpeg"] }, {
    content_kind: "recommendations", items: [
      { kind: "place", display_name: "聖水洞 水芹菜生牛肉拌飯", source_span: "image:1", origin_type: "inferred", confidence: "low", day_index: null, store_hint: null, store_evidence: null },
    ], template_days: [],
  });
  assert.equal(result.items[0]?.auto_archive, false);
  assert.equal(result.items[0]?.display_name, "聖水洞 水芹菜生牛肉拌飯");
});

test("公開貼文摘要有店名時可整理，未出現的店名仍會被丟棄", () => {
  const input = { title: null, rawText: "https://www.threads.com/share/example/",
    publicText: "無垢屋人蔘雞，這次吃聖水這家", imageBase64: [] };
  const result = validateResult(input, { content_kind: "recommendations", items: [
    { kind: "place", display_name: "無垢屋", source_span: "無垢屋人蔘雞", origin_type: "explicit", confidence: "high", day_index: null, store_hint: null, store_evidence: null },
    { kind: "place", display_name: "虛構餐廳", source_span: "虛構餐廳", origin_type: "explicit", confidence: "high", day_index: null, store_hint: null, store_evidence: null },
  ], template_days: [] });
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0]?.auto_archive, true);
});

test("商品的購買店名只保留有來源錨點的線索", () => {
  const input = { title: null, rawText: "在聖水洞的 IVYNYU LAB 挖到墨鏡", imageBase64: [] };
  const result = validateResult(input, { content_kind: "shopping", items: [
    { kind: "product", display_name: "墨鏡", source_span: "墨鏡", origin_type: "explicit", confidence: "high", day_index: null,
      store_hint: "IVYNYU LAB", store_evidence: "IVYNYU LAB" },
    { kind: "product", display_name: "香水", source_span: "image:1", origin_type: "explicit", confidence: "high", day_index: null,
      store_hint: "虛構店", store_evidence: "image:1" },
  ], template_days: [] });
  assert.equal(result.items[0]?.store_hint, "IVYNYU LAB");
  assert.equal(result.items.length, 1, "沒有圖片時 image:1 商品本身不應通過來源檢查");
});

test("原文否定的店名不會自動收藏或加入行程", () => {
  const input = { title: null, rawText: "Day 1 不要去 A咖啡，改去 B書店", imageBase64: [] };
  const result = validateResult(input, {
    content_kind: "itinerary", items: [
      { kind: "place", display_name: "A咖啡", source_span: "A咖啡", origin_type: "explicit", confidence: "high", day_index: 1, store_hint: null, store_evidence: null },
      { kind: "place", display_name: "B書店", source_span: "B書店", origin_type: "explicit", confidence: "high", day_index: 1, store_hint: null, store_evidence: null },
    ], template_days: [
      { day_index: 1, source_span: "Day 1 不要去 A咖啡，改去 B書店", stops: [
        { label: "A咖啡", source_span: "A咖啡", origin_type: "explicit" },
        { label: "B書店", source_span: "B書店", origin_type: "explicit" },
      ] },
    ],
  });
  assert.equal(result.items[0]?.auto_archive, false);
  assert.equal(result.items[1]?.auto_archive, true);
  assert.deepEqual(result.template_days[0]?.stops.map((stop) => stop.label), ["B書店"]);
});

test("三日行程保留來源天數，不從未提供的文字造停靠點", () => {
  const input = { title: null, rawText: "Day 1 明洞\nDay 2 弘大\nDay 3 聖水", imageBase64: [] };
  const result = validateResult(input, {
    content_kind: "itinerary", items: [], template_days: [
      { day_index: 1, source_span: "Day 1 明洞", stops: [{ label: "明洞", source_span: "明洞", origin_type: "explicit" }] },
      { day_index: 2, source_span: "Day 2 弘大", stops: [{ label: "弘大", source_span: "弘大", origin_type: "explicit" }] },
      { day_index: 3, source_span: "Day 3 聖水", stops: [{ label: "聖水", source_span: "聖水", origin_type: "explicit" }] },
      { day_index: 4, source_span: "Day 4 釜山", stops: [{ label: "釜山", source_span: "釜山", origin_type: "inferred" }] },
    ],
  });
  assert.deepEqual(result.template_days.map((day) => day.day_index), [1, 2, 3]);
});
