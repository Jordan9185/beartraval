import assert from "node:assert/strict";
import test from "node:test";
import { verifiedSuggestions } from "../src/discover.ts";

test("網路建議只接受有搜尋引用的來源，不接收模型自造網址", () => {
  const sources = [{ url: "https://example.com/restaurant", title: "聖水餐廳", citedText: "무구옥 성수점 서울 성동구 아차산로11길 11" }];
  const results = verifiedSuggestions({ candidates: [
    { name: "무구옥 성수점", korean_name: "무구옥 성수점", address_local: "서울 성동구 아차산로11길 11",
      search_query: "무구옥 성수점", reason: "聖水店", source_url: sources[0]!.url },
    { name: "虛構店", korean_name: null, address_local: null, search_query: "虛構店", reason: "模型推測", source_url: "https://fake.example/shop" },
  ] }, sources);
  assert.deepEqual(results.map((r) => r.name), ["무구옥 성수점"]);
  assert.equal(results[0]?.address_local, "서울 성동구 아차산로11길 11");
});

test("找得到店名但引用沒有地址時不顯示模型編造地址", () => {
  const sources = [{ url: "https://example.com/restaurant", title: "무구옥 성수점", citedText: "熱門人參雞" }];
  const result = verifiedSuggestions({ candidates: [{ name: "무구옥 성수점", korean_name: "무구옥 성수점",
    address_local: "서울 성동구 虛構街 999", search_query: "무구옥 성수점", reason: "聖水店", source_url: sources[0]!.url }] }, sources);
  assert.equal(result[0]?.address_local, null);
});

test("格式錯誤的網路建議不顯示", () => {
  assert.deepEqual(verifiedSuggestions({ candidates: [{ name: "只給名稱" }] }, []), []);
});
