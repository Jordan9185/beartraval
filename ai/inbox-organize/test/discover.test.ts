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

test("商品店家候選必須由引用文字支持具名店面", () => {
  const sources = [{ url: "https://example.com/shop", title: "이솝 성수점", citedText: "서울 성동구 연무장길 57" }];
  const input = { candidates: [
    { name: "Aesop Seongsu", korean_name: "이솝 성수점", address_local: "서울 성동구 연무장길 57",
      search_query: "이솝 성수점", reason: "品牌門市，商品是否販售待詢問", source_url: sources[0]!.url },
    { name: "虛構分店", korean_name: null, address_local: null,
      search_query: "虛構分店", reason: "品牌門市，商品是否販售待詢問", source_url: sources[0]!.url },
  ] };
  assert.deepEqual(verifiedSuggestions(input, sources, "product_store").map((item) => item.name), ["Aesop Seongsu"]);
});

test("中文譯名保留，日文原名必須有引用依據", () => {
  const sources = [{ url: "https://example.com/japan", title: "喫茶テスト", citedText: "東京都渋谷区測試地址" }];
  const candidate = { name: "測試咖啡", korean_name: "喫茶テスト", address_local: "東京都渋谷区測試地址",
    search_query: "喫茶テスト", reason: "日本店家", source_url: sources[0]!.url };
  const found = verifiedSuggestions({ candidates: [candidate] }, sources);
  assert.equal(found[0]?.name, "測試咖啡");
  assert.equal(found[0]?.korean_name, "喫茶テスト");
  const unsupported = verifiedSuggestions({ candidates: [{ ...candidate, korean_name: "捏造した支店" }] }, sources);
  assert.equal(unsupported[0]?.korean_name, null);
  assert.equal(unsupported[0]?.address_local, candidate.address_local);
});
