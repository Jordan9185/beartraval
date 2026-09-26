import assert from "node:assert/strict";
import test from "node:test";
import { validateResult } from "../src/organize.ts";

test("四間明確店家各自歸檔，沒有來源錨點的項目被丟棄", () => {
  const text = "聖水洞：A咖啡、B麵包、C書店、D選物。";
  const items = ["A咖啡", "B麵包", "C書店", "D選物"].map((name) => ({
    kind: "place", display_name: name, source_span: name, origin_type: "explicit", confidence: "high", day_index: null,
  }));
  const result = validateResult({ title: null, rawText: text, imageBase64: [] }, {
    content_kind: "recommendations", items: [...items, { ...items[0], display_name: "虛構店", source_span: "虛構店" }], template_days: [],
  });
  assert.equal(result.items.length, 4);
  assert.ok(result.items.every((item) => item.auto_archive));
});

test("照片與歧義分店僅保留候選，不自動歸檔", () => {
  const result = validateResult({ title: null, rawText: "A咖啡可能是明洞或弘大分店", imageBase64: ["jpeg"] }, {
    content_kind: "mixed", items: [
      { kind: "place", display_name: "A咖啡", source_span: "A咖啡可能是明洞或弘大分店", origin_type: "explicit", confidence: "high", day_index: null },
      { kind: "product", display_name: "ReFa", source_span: "image:1", origin_type: "explicit", confidence: "high", day_index: null },
    ], template_days: [],
  });
  assert.ok(result.items.every((item) => !item.auto_archive));
});

test("原文否定的店名不會自動收藏或加入行程", () => {
  const input = { title: null, rawText: "Day 1 不要去 A咖啡，改去 B書店", imageBase64: [] };
  const result = validateResult(input, {
    content_kind: "itinerary", items: [
      { kind: "place", display_name: "A咖啡", source_span: "A咖啡", origin_type: "explicit", confidence: "high", day_index: 1 },
      { kind: "place", display_name: "B書店", source_span: "B書店", origin_type: "explicit", confidence: "high", day_index: 1 },
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
