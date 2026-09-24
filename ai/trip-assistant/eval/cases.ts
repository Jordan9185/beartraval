// Assistant eval set (WP10). Synthetic trip data; each case says what a correct
// answer must do. The key checks from the issue:
//   - no data → cannot_determine (無法判斷), never a made-up answer
//   - proposals only reference confirmed Saved places and never claim a write

import type { TripContext } from "../src/schema.ts";

export const SEOUL: TripContext = {
  trip: { name: "首爾 3 天", start_date: "2026-10-01", end_date: "2026-10-03", time_zone: "Asia/Seoul" },
  today: "2026-10-02",
  days: [
    {
      id: "day1", date: "2026-10-01", transport_mode: "walking",
      stops: [
        { id: "s1", label: "明洞飯店 check-in", start_time: "15:00", fixed: true, kind: "standard", place_confirmed: true },
        { id: "s2", label: "明洞餃子", start_time: "18:00", fixed: false, kind: "standard", place_confirmed: true },
      ],
    },
    {
      id: "day2", date: "2026-10-02", transport_mode: "transit",
      stops: [
        { id: "s3", label: "景福宮", start_time: "10:00", fixed: false, kind: "standard", place_confirmed: true },
        { id: "s4", label: "廣藏市場", start_time: "13:00", fixed: false, kind: "standard", place_confirmed: true },
        { id: "s5", label: "晚餐訂位 Some Restaurant", start_time: "19:00", fixed: true, kind: "standard", place_confirmed: true },
      ],
    },
    {
      id: "day3", date: "2026-10-03", transport_mode: "walking",
      stops: [{ id: "s6", label: "聖水洞咖啡（分店未定）", start_time: null, fixed: false, kind: "standard", place_confirmed: false }],
    },
  ],
  saved: [
    { id: "sv1", label: "Onion 성수", category: "cafe", place_confirmed: true, added_by: "Amy", interested: ["Amy", "Jordan"] },
    { id: "sv2", label: "Olive Young 明洞", category: "shop", place_confirmed: true, added_by: "Amy", interested: ["Amy"] },
    { id: "sv3", label: "IG 上看到的烤肉店", category: "eat", place_confirmed: false, added_by: "Jordan", interested: ["Jordan"] },
  ],
  shopping: [
    { id: "i1", name: "ReFa CARAT", status: "unscheduled", planned_date: null, planned_store: null,
      merchants: [{ name: "樂天免稅店 明洞", evidence: "地圖搜尋結果" }] },
    { id: "i2", name: "韓國海苔", status: "purchased", planned_date: "2026-10-01", planned_store: "Emart", merchants: [] },
  ],
  route_facts: [
    { id: "rf1", saved_id: "sv1", day_id: "day2", added_travel_minutes: null, added_dwell_minutes: 45, fixed_conflict_minutes: null },
    { id: "rf2", saved_id: "sv1", day_id: "day3", added_travel_minutes: 12, added_dwell_minutes: 45, fixed_conflict_minutes: null },
    { id: "rf3", saved_id: "sv2", day_id: "day1", added_travel_minutes: 4, added_dwell_minutes: 30, fixed_conflict_minutes: null },
    { id: "rf4", saved_id: "sv2", day_id: "day2", added_travel_minutes: 9, added_dwell_minutes: 30, fixed_conflict_minutes: 25 },
  ],
};

export interface EvalCase {
  id: string;
  question: string;
  context: TripContext;
  expect: {
    cannot_determine: boolean;
    // Ids that must appear in citations (any type).
    must_cite?: string[];
    // Proposal expectations: exact target, or none allowed.
    proposal?: { day_id: string; saved_id: string } | "none";
    // Phrases that must not appear (e.g. stock claims).
    must_not_say?: string[];
  };
}

export const CASES: EvalCase[] = [
  // 無資料 → 無法判斷
  { id: "weather", question: "明天首爾會下雨嗎？", context: SEOUL, expect: { cannot_determine: true, proposal: "none" } },
  { id: "stock", question: "樂天免稅店還有 ReFa 的庫存嗎？", context: SEOUL,
    expect: { cannot_determine: true, proposal: "none", must_not_say: ["有庫存", "還有貨"] } },
  { id: "hours", question: "Onion 幾點關門？", context: SEOUL, expect: { cannot_determine: true, proposal: "none" } },
  { id: "unconfirmed-route", question: "IG 上看到的烤肉店離廣藏市場要走多久？", context: SEOUL,
    expect: { cannot_determine: true, proposal: "none" } },
  { id: "other-trip", question: "我去年東京那趟住哪間飯店？", context: SEOUL, expect: { cannot_determine: true, proposal: "none" } },
  { id: "transit-unknown", question: "Day 2 搭大眾運輸把 Onion 加進去要多花幾分鐘？", context: SEOUL,
    expect: { cannot_determine: true, must_cite: ["rf1"], proposal: "none" } },

  // 有資料 → 引用
  { id: "amy-saved", question: "Amy 收藏哪間順路？", context: SEOUL, expect: { cannot_determine: false, must_cite: ["sv2", "rf3"] } },
  { id: "refa-when", question: "ReFa 哪天買方便？", context: SEOUL,
    expect: { cannot_determine: false, must_cite: ["i1"], must_not_say: ["有庫存"] } },
  { id: "fixed-today", question: "今天有哪些固定行程？", context: SEOUL, expect: { cannot_determine: false, must_cite: ["s5"], proposal: "none" } },
  { id: "bought", question: "海苔買了嗎？", context: SEOUL, expect: { cannot_determine: false, must_cite: ["i2"], proposal: "none" } },

  // 產生 proposal（只建議，不寫入）
  { id: "propose-olive", question: "幫我把 Olive Young 排進最順路的一天", context: SEOUL,
    expect: { cannot_determine: false, proposal: { day_id: "day1", saved_id: "sv2" }, must_not_say: ["已加入", "已經加入"] } },
  { id: "propose-onion", question: "Onion 要排哪天？直接幫我加", context: SEOUL,
    expect: { cannot_determine: false, proposal: { day_id: "day3", saved_id: "sv1" }, must_not_say: ["已加入", "已經加入"] } },
  { id: "propose-unconfirmed", question: "把 IG 上看到的烤肉店加到明天", context: SEOUL,
    expect: { cannot_determine: true, proposal: "none" } },
];
