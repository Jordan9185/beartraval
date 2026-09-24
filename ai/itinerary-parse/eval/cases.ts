// Eval set for itinerary parsing (issue #3).
//
// These are SYNTHETIC itineraries written to cover known formats and traps. Real
// itineraries from travellers should be added (and weighted) as they are
// collected; see README.
//
// Expectations are deliberately partial: they list what must be right, not a
// full golden output. A stop matches when any alias appears in the predicted
// place_name (or excerpt), after lowercasing and removing spaces.

import type { ConfirmationReason } from "../src/schema.ts";

export interface ExpectedStop {
  // Trip date the stop belongs to, or null when it must be left undated.
  date: string | null;
  aliases: string[];
  start_time?: string | null;
  fixed?: boolean;
  // Reasons that must be flagged (others may appear too).
  flags?: ConfirmationReason[];
  // Reasons that must NOT be flagged.
  not_flags?: ConfirmationReason[];
}

export interface EvalCase {
  id: string;
  source: "chatgpt" | "line" | "memo" | "other";
  tripStart: string;
  tripEnd: string;
  timeZone: string;
  rawText: string;
  expected: ExpectedStop[];
  // Text that must not become a stop (reminders, budgets, chatter).
  mustNotInclude?: string[];
}

const SEOUL = { tripStart: "2026-10-01", tripEnd: "2026-10-04", timeZone: "Asia/Seoul" } as const;
const HIROSHIMA = { tripStart: "2026-11-10", tripEnd: "2026-11-12", timeZone: "Asia/Tokyo" } as const;

export const CASES: EvalCase[] = [
  {
    id: "seoul-chatgpt-markdown",
    source: "chatgpt",
    ...SEOUL,
    rawText: `## 首爾 4 天 3 夜行程

### Day 1（10/1）
- 10:30 抵達仁川機場（KE692）
- 14:00 飯店 Check-in：Lotte Hotel Seoul
- 16:00 明洞逛街
- 19:00 晚餐：明洞餃子

### Day 2（10/2）
- 09:30 景福宮（記得穿韓服可免費入場）
- 12:00 午餐：土俗村蔘雞湯
- 15:00 北村韓屋村
- 19:30 晚餐 Mingles（已預約）

### Day 3（10/3）
- 11:00 聖水洞咖啡廳 Onion
- 14:00 XXX Shoes 聖水店
- 18:00 弘大

### Day 4（10/4）
- 10:00 樂天超市採買
- 14:30 仁川機場 KE691 起飛`,
    expected: [
      { date: "2026-10-01", aliases: ["仁川", "incheon", "ke692"], start_time: "10:30", fixed: true },
      { date: "2026-10-01", aliases: ["lotte hotel"], start_time: "14:00" },
      { date: "2026-10-01", aliases: ["明洞餃子"], start_time: "19:00" },
      { date: "2026-10-02", aliases: ["景福宮"], start_time: "09:30" },
      { date: "2026-10-02", aliases: ["土俗村"], start_time: "12:00" },
      { date: "2026-10-02", aliases: ["mingles"], start_time: "19:30", fixed: true },
      { date: "2026-10-03", aliases: ["onion"], start_time: "11:00" },
      { date: "2026-10-03", aliases: ["xxxshoes"], start_time: "14:00", not_flags: ["ambiguous_branch"] },
      { date: "2026-10-04", aliases: ["樂天超市", "lottemart"], flags: ["ambiguous_branch"] },
      { date: "2026-10-04", aliases: ["ke691", "仁川"], start_time: "14:30", fixed: true },
    ],
    mustNotInclude: ["穿韓服"],
  },
  {
    id: "seoul-line-chat-ambiguous-branch",
    source: "line",
    ...SEOUL,
    rawText: `Jordan: 10/2 下午想去 XXX Shoes 買鞋
Amy: 好啊 哪一間？
Jordan: 還沒決定 明洞跟聖水都有
Amy: 那晚上 7 點我訂了 Jungsik 喔
Jordan: 👍 10/3 早上去廣藏市場吃早餐`,
    expected: [
      { date: "2026-10-02", aliases: ["xxxshoes"], flags: ["ambiguous_branch"] },
      { date: "2026-10-02", aliases: ["jungsik"], start_time: "19:00", fixed: true },
      { date: "2026-10-03", aliases: ["廣藏市場", "gwangjang"], flags: ["ambiguous_time"] },
    ],
  },
  {
    id: "seoul-memo-no-times",
    source: "memo",
    ...SEOUL,
    rawText: `首爾清單
10/1
- 東大門 DDP
- 陳玉華一隻雞
10/2
- 南山塔
- 梨泰院
10/3
- COEX 星空圖書館
- 奉恩寺`,
    expected: [
      { date: "2026-10-01", aliases: ["ddp", "東大門"], start_time: null },
      { date: "2026-10-01", aliases: ["陳玉華"], start_time: null },
      { date: "2026-10-02", aliases: ["南山"], start_time: null },
      { date: "2026-10-02", aliases: ["梨泰院"], start_time: null },
      { date: "2026-10-03", aliases: ["星空圖書館", "starfield", "coex"], start_time: null },
      { date: "2026-10-03", aliases: ["奉恩寺"], start_time: null },
    ],
  },
  {
    id: "seoul-korean",
    source: "memo",
    ...SEOUL,
    rawText: `10월 2일
09:00 경복궁
12:30 광화문 미진 (메밀국수)
15:00 익선동 카페거리
18:30 을지로 노가리 골목

10월 3일
10:00 성수동 대림창고
13:00 서울숲
19:00 저녁 예약 - 몽탄`,
    expected: [
      { date: "2026-10-02", aliases: ["경복궁"], start_time: "09:00" },
      { date: "2026-10-02", aliases: ["미진"], start_time: "12:30" },
      { date: "2026-10-02", aliases: ["익선동"], start_time: "15:00" },
      { date: "2026-10-02", aliases: ["노가리"], start_time: "18:30" },
      { date: "2026-10-03", aliases: ["대림창고"], start_time: "10:00" },
      { date: "2026-10-03", aliases: ["서울숲"], start_time: "13:00" },
      { date: "2026-10-03", aliases: ["몽탄"], start_time: "19:00", fixed: true },
    ],
  },
  {
    id: "seoul-day-labels",
    source: "chatgpt",
    ...SEOUL,
    rawText: `Day 1: Arrive, check in at L7 Myeongdong, dinner at Myeongdong Kyoja
Day 2: Changdeokgung Secret Garden tour 10:00 (tickets booked), lunch at Tosokchon
Day 3: Lotte World Tower Seoul Sky, shopping at Starfield Coex
Day 4: Fly home`,
    expected: [
      { date: "2026-10-01", aliases: ["l7"] },
      { date: "2026-10-01", aliases: ["kyoja"] },
      { date: "2026-10-02", aliases: ["changdeokgung", "secretgarden"], start_time: "10:00", fixed: true },
      { date: "2026-10-02", aliases: ["tosokchon"] },
      { date: "2026-10-03", aliases: ["seoulsky", "lotteworldtower"] },
      { date: "2026-10-03", aliases: ["starfield", "coex"] },
    ],
  },
  {
    id: "seoul-weekday-labels",
    source: "line",
    ...SEOUL,
    rawText: `週四：到了先去廣藏市場
週五：梨花女大、延南洞
週六：一整天樂天世界
週日：早上漢江公園騎腳踏車 下午回台灣`,
    expected: [
      { date: "2026-10-01", aliases: ["廣藏市場"] },
      { date: "2026-10-02", aliases: ["梨花"] },
      { date: "2026-10-02", aliases: ["延南洞"] },
      { date: "2026-10-03", aliases: ["樂天世界"] },
      { date: "2026-10-04", aliases: ["漢江"] },
    ],
  },
  {
    id: "seoul-chains",
    source: "memo",
    ...SEOUL,
    rawText: `10/3 購物
- Olive Young 買面膜
- Daiso
- 弘大 ABC Mart
- 星巴克休息`,
    expected: [
      { date: "2026-10-03", aliases: ["oliveyoung"], flags: ["ambiguous_branch"] },
      { date: "2026-10-03", aliases: ["daiso"], flags: ["ambiguous_branch"] },
      { date: "2026-10-03", aliases: ["abcmart"], not_flags: ["ambiguous_branch"] },
      { date: "2026-10-03", aliases: ["星巴克", "starbucks"], flags: ["ambiguous_branch"] },
    ],
  },
  {
    id: "seoul-time-ranges",
    source: "chatgpt",
    ...SEOUL,
    rawText: `10/2
14:00–16:00 國立中央博物館
16:30-17:30 戰爭紀念館
18:00~20:00 梨泰院晚餐 Plant Cafe`,
    expected: [
      { date: "2026-10-02", aliases: ["中央博物館"], start_time: "14:00" },
      { date: "2026-10-02", aliases: ["戰爭紀念館"], start_time: "16:30" },
      { date: "2026-10-02", aliases: ["plant"], start_time: "18:00" },
    ],
  },
  {
    id: "seoul-vague-times",
    source: "line",
    ...SEOUL,
    rawText: `10/1 中午左右到飯店放行李（Nine Tree Premier 明洞2）
傍晚去南大門市場
晚上想吃烤肉 王妃家`,
    expected: [
      { date: "2026-10-01", aliases: ["ninetree"], flags: ["ambiguous_time"] },
      { date: "2026-10-01", aliases: ["南大門"], flags: ["ambiguous_time"] },
      { date: "2026-10-01", aliases: ["王妃家"], flags: ["ambiguous_time"] },
    ],
  },
  {
    id: "seoul-noise",
    source: "memo",
    ...SEOUL,
    rawText: `預算：每人 30 萬韓元
記得帶轉接頭、T-money 卡要先儲值
換錢：明洞換錢所匯率最好

10/2
10:00 北村韓屋村
13:00 三清洞 Café Onion Anguk

注意：週一很多景點休館`,
    expected: [
      { date: "2026-10-02", aliases: ["北村"], start_time: "10:00" },
      { date: "2026-10-02", aliases: ["onion"], start_time: "13:00", not_flags: ["ambiguous_branch"] },
    ],
    mustNotInclude: ["預算", "轉接頭", "t-money", "休館"],
  },
  {
    id: "seoul-mixed-date-formats",
    source: "other",
    ...SEOUL,
    rawText: `Oct 1 - Hongdae street food
10/2 - 汝矣島 The Hyundai Seoul
3日 - 樂天世界塔
2026-10-04 11:00 - Incheon Airport T2 check-in`,
    expected: [
      { date: "2026-10-01", aliases: ["hongdae"] },
      { date: "2026-10-02", aliases: ["hyundai"] },
      { date: "2026-10-03", aliases: ["樂天世界塔"] },
      { date: "2026-10-04", aliases: ["incheon"], start_time: "11:00" },
    ],
  },
  {
    id: "seoul-out-of-range",
    source: "line",
    ...SEOUL,
    rawText: `10/2 益善洞
10/6 首爾大公園（如果延長住宿的話）`,
    expected: [
      { date: "2026-10-02", aliases: ["益善洞"] },
      { date: null, aliases: ["首爾大公園"], flags: ["ambiguous_date"] },
    ],
  },
  {
    id: "seoul-duplicate-place",
    source: "chatgpt",
    ...SEOUL,
    rawText: `10/1 晚上 明洞夜市
10/3 晚上 再去一次明洞夜市買伴手禮`,
    expected: [
      { date: "2026-10-01", aliases: ["明洞夜市"] },
      { date: "2026-10-03", aliases: ["明洞夜市"] },
    ],
  },
  {
    id: "seoul-english-reservations",
    source: "other",
    ...SEOUL,
    rawText: `Thu 10/1: land 13:05 (CI160), hotel Four Seasons Seoul
Fri 10/2: 11:00 DMZ tour pickup at Hongik Univ. Stn exit 8 (booked on Klook)
Sat 10/3: 18:00 NANTA show, Myeongdong theater (tickets)
Sun 10/4: brunch somewhere in Seongsu, 16:20 flight CI161`,
    expected: [
      { date: "2026-10-01", aliases: ["ci160"], start_time: "13:05", fixed: true },
      { date: "2026-10-01", aliases: ["fourseasons"] },
      { date: "2026-10-02", aliases: ["dmz", "hongik"], start_time: "11:00", fixed: true },
      { date: "2026-10-03", aliases: ["nanta"], start_time: "18:00", fixed: true },
      { date: "2026-10-04", aliases: ["ci161"], start_time: "16:20", fixed: true },
    ],
  },
  {
    id: "hiroshima-chatgpt",
    source: "chatgpt",
    ...HIROSHIMA,
    rawText: `### 11/10 廣島市區
- 11:00 廣島站抵達
- 12:00 お好み村 午餐
- 14:00 原爆圓頂館、和平紀念公園
- 16:00 和平紀念資料館

### 11/11 宮島
- 09:10 宮島口搭 JR 渡輪
- 10:00 嚴島神社
- 12:30 牡蠣屋 午餐
- 15:00 彌山纜車

### 11/12
- 10:00 縮景園
- 13:40 廣島站 新幹線 のぞみ 回大阪`,
    expected: [
      { date: "2026-11-10", aliases: ["廣島站", "hiroshimastation"], start_time: "11:00" },
      { date: "2026-11-10", aliases: ["お好み村"], start_time: "12:00" },
      { date: "2026-11-10", aliases: ["原爆", "和平紀念公園"], start_time: "14:00" },
      { date: "2026-11-10", aliases: ["資料館"], start_time: "16:00" },
      { date: "2026-11-11", aliases: ["渡輪", "宮島口"], start_time: "09:10", fixed: true },
      { date: "2026-11-11", aliases: ["嚴島神社"], start_time: "10:00" },
      { date: "2026-11-11", aliases: ["牡蠣屋"], start_time: "12:30" },
      { date: "2026-11-11", aliases: ["彌山", "纜車"], start_time: "15:00" },
      { date: "2026-11-12", aliases: ["縮景園"], start_time: "10:00" },
      { date: "2026-11-12", aliases: ["のぞみ", "新幹線"], start_time: "13:40", fixed: true },
    ],
  },
  {
    id: "hiroshima-japanese",
    source: "memo",
    ...HIROSHIMA,
    rawText: `11月10日（火）
13:00 八昌 お好み焼き（予約済み）
15:00 本通り商店街
18:30 かき船 かなわ 予約

11月11日（水）
午前 尾道へ移動
千光寺
ラーメン 朱華園`,
    expected: [
      { date: "2026-11-10", aliases: ["八昌"], start_time: "13:00", fixed: true },
      { date: "2026-11-10", aliases: ["本通"], start_time: "15:00" },
      { date: "2026-11-10", aliases: ["かなわ"], start_time: "18:30", fixed: true },
      { date: "2026-11-11", aliases: ["千光寺"] },
      { date: "2026-11-11", aliases: ["朱華園"] },
    ],
  },
  {
    id: "hiroshima-train-fixed",
    source: "other",
    ...HIROSHIMA,
    rawText: `11/10 08:12 新大阪 → 09:40 広島（のぞみ 5 号, 指定席 7車 12A）
11/10 10:30 Mazda Museum 見学（要予約、予約番号 A123）
11/10 14:00 マツダスタジアム周辺散歩`,
    expected: [
      { date: "2026-11-10", aliases: ["のぞみ", "新大阪"], start_time: "08:12", fixed: true },
      { date: "2026-11-10", aliases: ["mazdamuseum"], start_time: "10:30", fixed: true },
      { date: "2026-11-10", aliases: ["マツダスタジアム"], start_time: "14:00", fixed: false },
    ],
  },
  {
    id: "hiroshima-no-dates",
    source: "memo",
    ...HIROSHIMA,
    rawText: `廣島想去
- 廣島城
- 蔦屋家電 廣島
- 平和大通り`,
    expected: [
      { date: null, aliases: ["廣島城"], flags: ["ambiguous_date"] },
      { date: null, aliases: ["蔦屋"], flags: ["ambiguous_date"] },
      { date: null, aliases: ["平和大通"], flags: ["ambiguous_date"] },
    ],
  },
  {
    id: "hiroshima-branch-hints",
    source: "line",
    ...HIROSHIMA,
    rawText: `11/12 早上 広島駅のスタバで集合
然後去 ekie 買もみじ饅頭（にしき堂）
中午 お好み焼き 電光石火 駅前ひろば店`,
    expected: [
      { date: "2026-11-12", aliases: ["スタバ", "starbucks"], not_flags: ["ambiguous_branch"] },
      { date: "2026-11-12", aliases: ["ekie", "にしき堂"] },
      { date: "2026-11-12", aliases: ["電光石火"], not_flags: ["ambiguous_branch"] },
    ],
  },
  {
    id: "hiroshima-mixed-language",
    source: "chatgpt",
    ...HIROSHIMA,
    rawText: `Day 2 (Wed): Miyajima
- Take the 8:45 ferry from Miyajimaguchi (JR)
- Itsukushima Shrine
- Lunch: 牡蠣料理 焼がきのはやし
- Afternoon: Momiji-dani Park`,
    expected: [
      { date: "2026-11-11", aliases: ["ferry", "miyajimaguchi"], start_time: "08:45", fixed: true },
      { date: "2026-11-11", aliases: ["itsukushima"] },
      { date: "2026-11-11", aliases: ["はやし"] },
      { date: "2026-11-11", aliases: ["momiji"], flags: ["ambiguous_time"] },
    ],
  },
  {
    id: "no-places",
    source: "line",
    ...SEOUL,
    rawText: `到時候再看天氣決定要去哪
大家記得護照
匯率現在大概 1:42`,
    expected: [],
    mustNotInclude: ["護照", "匯率", "天氣"],
  },
  {
    id: "seoul-unknown-place",
    source: "line",
    ...SEOUL,
    rawText: `10/2 下午去朋友推薦的那家小店
10/2 晚上 廣藏市場 麻藥紫菜飯捲`,
    expected: [
      { date: "2026-10-02", aliases: ["朋友推薦", "小店"], flags: ["unknown_place"] },
      { date: "2026-10-02", aliases: ["廣藏市場", "麻藥"] },
    ],
  },
];
