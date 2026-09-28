import assert from "node:assert/strict";
import test from "node:test";
import { verifiedRecommendations, verifyNearbyAnswer } from "../src/ask.ts";
import { validateAnswer, hasSharedArea } from "../src/validate.ts";
import { SEOUL } from "../eval/cases.ts";
import type { AssistantAnswer } from "../src/schema.ts";

const base: AssistantAnswer = { answer: "仍需確認", cannot_determine: false, citations: [], proposal: null };
test("餐廳無引用評分及路程回到未知，不保留虛構分數", () => {
  const item = { name: "測試店", category: "food" as const, introduction: "甜點", source_url: "https://example.com/shop", visit_note: "營業待查",
    route: { description: "步行8分鐘", source_url: "https://example.com/route", evidence: "8分鐘" },
    rating: { display: "4.4/5", platform: "某平台", reviews: "128", source_url: "https://example.com/shop", evidence: "4.4/5" } };
  const result = verifiedRecommendations([item], [{ url: item.source_url, title: "測試店", citedText: "測試店的甜點" }]);
  assert.equal(result.length, 1);
  assert.equal(result[0]!.route, null);
  assert.equal(result[0]!.rating, null);
  assert.deepEqual(verifiedRecommendations([item], []), []);
});
test("沒有行程既有站點作為同區域依據，不提供採買排日", () => {
  const context = structuredClone(SEOUL);
  const item = context.shopping[0]!;
  item.status = "unscheduled";
  item.store_candidates = [{ name: "弘大商店", address: "弘大", source_url: "https://example.com/hongdae" }];
  const answer = validateAnswer(context, { ...base, shopping_proposal: { item_id: item.id,
    day_id: context.days[0]!.id, source_url: "https://example.com/hongdae", anchor_stop_id: "new-district", reason: "商品只在另一區" } }).answer;
  assert.equal(answer.shopping_proposal, null);
});
test("未定位但有店家地址線索可以提出收藏排日，未知身分仍不可", () => {
  const context = structuredClone(SEOUL);
  const saved = context.saved.find((s) => !s.place_confirmed)!;
  saved.address = "已保存的店家地址線索";
  const proposal = { saved_id: saved.id, day_id: context.days[0]!.id, reason: "同區域" };
  assert.deepEqual(validateAnswer(context, { ...base, proposal }).answer.proposal, proposal);
  saved.address = null;
  assert.equal(validateAnswer(context, { ...base, proposal }).answer.proposal, null);
});

test("聖水既有站不能被弘大店家借用當順路依據，城市相同也不算", () => {
  const seongsu = { label: "聖水洞", address: "서울특별시 성동구 성수동" };
  const hongdae = { name: "弘大商店", address: "서울특별시 마포구 홍대" };
  assert.equal(hasSharedArea("서울특별시", hongdae, seongsu), false);
  assert.equal(hasSharedArea("성동구", hongdae, seongsu), false);
  assert.equal(hasSharedArea("성동구", { name: "商店", address: "서울특별시 성동구 測試街道" }, seongsu), true);
  assert.equal(hasSharedArea(null, hongdae, seongsu), false);
  const context = structuredClone(SEOUL); const item = context.shopping[0]!;
  item.status = "unscheduled";
  item.store_candidates = [{ ...hongdae, source_url: "https://example.com/hongdae" }];
  Object.assign(context.days[0]!.stops[0]!, seongsu);
  const proposal = { item_id: item.id, day_id: context.days[0]!.id, source_url: "https://example.com/hongdae",
    anchor_stop_id: context.days[0]!.stops[0]!.id, matched_area: "서울특별시", reason: "城市相同" };
  assert.equal(validateAnswer(context, { ...base, shopping_proposal: proposal }).answer.shopping_proposal, null);
});

test("有路程引用仍不可拿其他起點或改寫的分鐘數冒充本站路程", () => {
  const url = "https://example.test/route";
  const item = { name: "甜點店", category: "food" as const, introduction: "甜點", source_url: url, visit_note: "待查", rating: null,
    route: { description: "步行8分鐘", source_url: url, evidence: "機場到甜點店步行8分鐘" } };
  const sources = [{ url, title: "甜點店", citedText: "機場到甜點店步行8分鐘；本站到甜點店步行12分鐘" }];
  assert.equal(verifiedRecommendations([item], sources, "本站")[0]!.route, null);
  item.route.evidence = "本站到甜點店步行12分鐘";
  assert.equal(verifiedRecommendations([item], sources, "本站")[0]!.route, null);
  item.route.description = "步行12分鐘";
  assert.equal(verifiedRecommendations([item], sources, "本站")[0]!.route?.description, "步行12分鐘");
});
test("特殊活動必須有覆蓋到訪日的來源日期，過期或缺日期不推薦", () => {
  const url = "https://example.test/event";
  const item = { name: "秋日市集", category: "event" as const, introduction: "市集", source_url: url, visit_note: "期間開放", route: null, rating: null,
    event_period: { start_date: "2026-10-01", end_date: "2026-10-03", source_url: url, evidence: "秋日市集 2026-10-01 至 2026-10-03" } };
  const sources = [{ url, title: "秋日市集", citedText: item.event_period.evidence }];
  assert.equal(verifiedRecommendations([item], sources, "本站", "2026-10-02").length, 1);
  assert.equal(verifiedRecommendations([item], sources, "本站", "2026-10-04").length, 0);
  assert.equal(verifiedRecommendations([{ ...item, event_period: null }], sources, "本站", "2026-10-02").length, 0);
});

test("剔除未證實的候選後，文字答案不能繼續宣稱虛構時間或活動", () => {
  const answer: AssistantAnswer = { ...base, answer: "明天有市集，走8分鐘就到", recommendations: [{
    name: "已過期市集", category: "event", introduction: "活動", source_url: "https://example.test/old",
    route: null, rating: null, visit_note: "明天開放", event_period: null,
  }] };
  verifyNearbyAnswer(answer, [], "本站", "2026-10-02");
  assert.equal(answer.cannot_determine, true);
  assert.equal(answer.recommendations?.length, 0);
  assert.equal(answer.answer.includes("走8分鐘"), false);
  assert.equal(answer.answer.includes("明天有市集"), false);
});

test("原行程變更只接受非固定站，移除須對應原日且不接受同站兩種操作", () => {
  const context = structuredClone(SEOUL);
  const day = context.days[0]!;
  const stop = day.stops[0]!;
  const action = { kind: "stop_move" as const, item_id: stop.id, day_id: day.id, source_url: null, anchor_stop_id: null, reason: "使用者指定" };
  stop.fixed = true;
  assert.equal(validateAnswer(context, { ...base, arrangements: [action] }).answer.arrangements?.length, 0);
  stop.fixed = false;
  assert.equal(validateAnswer(context, { ...base, arrangements: [action] }).answer.arrangements?.length, 1);
  assert.equal(validateAnswer(context, { ...base, arrangements: [action, { ...action, kind: "stop_remove" }] }).answer.arrangements?.length, 0);
  assert.equal(validateAnswer(context, { ...base, arrangements: [{ ...action, kind: "stop_remove", day_id: "other-day" }] }).answer.arrangements?.length, 0);
});

test("安排時間必須是合法當地時刻，移除操作不能夾帶時間變更", () => {
  const context = structuredClone(SEOUL); const day = context.days[0]!; const stop = day.stops[0]!;
  stop.fixed = false;
  const action = { kind: "stop_move" as const, item_id: stop.id, day_id: day.id, start_time: "09:30", source_url: null, anchor_stop_id: null, reason: "使用者指定" };
  assert.equal(validateAnswer(context, { ...base, arrangements: [action] }).answer.arrangements?.length, 1);
  assert.equal(validateAnswer(context, { ...base, arrangements: [{ ...action, start_time: "24:30" }] }).answer.arrangements?.length, 0);
  assert.equal(validateAnswer(context, { ...base, arrangements: [{ ...action, kind: "stop_remove" }] }).answer.arrangements?.length, 0);
});
