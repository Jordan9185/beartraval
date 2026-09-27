import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod/v4";

const Stop = z.object({
  label: z.string().min(1).max(200),
  source_span: z.string().min(1).max(500),
  origin_type: z.enum(["explicit", "inferred"]),
});
const Day = z.object({
  day_index: z.number().int().min(1).max(30).nullable(),
  source_span: z.string().min(1).max(500),
  stops: z.array(Stop).max(30),
});
const Item = z.object({
  kind: z.enum(["place", "product"]),
  display_name: z.string().min(1).max(200),
  source_span: z.string().min(1).max(500),
  origin_type: z.enum(["explicit", "inferred"]),
  confidence: z.enum(["high", "medium", "low"]),
  day_index: z.number().int().min(1).max(30).nullable(),
  store_hint: z.string().max(200).nullable(),
  store_evidence: z.string().max(500).nullable(),
});
export const InboxResult = z.object({
  content_kind: z.enum(["recommendations", "shopping", "itinerary", "mixed", "unknown"]),
  items: z.array(Item).max(30),
  template_days: z.array(Day).max(30),
});

export type InboxInput = { title: string | null; rawText: string; publicText?: string | null; imageBase64: string[] };
export type ValidatedResult = Omit<z.infer<typeof InboxResult>, "items"> & {
  items: Array<z.infer<typeof Item> & { auto_archive: boolean }>;
};

const SYSTEM_PROMPT = `你是 BeaRTravel 分享內容整理器。只辨識使用者實際分享的文字與圖片，以及系統明確提供的公開貼文摘要 public_post_text；不自行開啟網址、不推斷未提供的貼文或影片內容。
先判斷使用意圖再分類：place 是「想去／想吃／想逛的地方」，product 是「想買帶走的東西」。餐廳現做料理、必點菜、冷麵、人蔘雞、烤肉、咖啡飲品屬用餐目的，不是購物商品。只有料理名而找不到店名時仍用 place，保留料理與地區作搜尋線索，confidence=low，不捏造餐廳。包裝零食、料理包、瓶裝醬料、伴手禮才用 product。不能因為都是食物就用同一分類。
同篇店家與必點菜合為一筆 place，店名作 display_name，必吃資訊保留在 source_span；沒有店名才以料理作名稱。同篇另外推薦帶走的商品則另列 product，store_hint 連回來源明示的店家。無法判定吃或買時 confidence=low，留待使用者更正，不自動歸檔。
輸出所有明確出現的地點、商品，以及來源明示的行程天數和順序。每項 source_span 必須是輸入文字的原文短句；若只來自第 1 張圖片，寫 image:1（依序類推）。
沒有可辨識的店家、用餐線索、商品或停靠點時，items 和 template_days 留空。「不要去／避雷／不要買」提到的對象不是收藏或行程停靠點。圖片中可讀到明確的店名或商品名稱時才給 high；只有區域與料理名稱（例如「聖水洞 水芹菜生牛肉拌飯」）時保留完整搜尋線索、給 low，不能當作已確認餐廳。地點有多個分店而來源未指明時，confidence 用 medium 或 low。
商品若有明確的購買店家、櫃位或店面招牌，填 store_hint（店名，不填地區）與 store_evidence（原文片段或 image:N）；沒有就填 null。只有同一篇貼文的文字或相片能互相支持店家線索；不可把相鄰貼文的招牌、背景路過的商店或爐具品牌綁成購買店家。品牌可保留為待確認的購物線索，但不能當成特定門市，也不要宣稱有庫存。
先辨識每篇貼文與留言的邊界，再分別抽取。手機時間、電量、搜尋列、帳號、發文日期、愛心或瀏覽數、按鈕和回覆欄不是地點或商品；搜尋列只可作區域背景。巢狀截圖中的平台名（例如 Trip.com）不是商店。
明確推薦的留言可抽取；提問舉例的料理、照片中的食物不是已知店名。只有料理或局部招牌時，保留可見文字作低信心搜尋線索，不補出完整品牌、型號、地址或分店。重複圖片與相同項目不要重複列出；不同分店、規格仍分開保留。截圖上的售價、折扣只是原作者陳述，不當作目前價格。
他人的日期、訂位不能當成使用者已訂的固定行程。圖片先後不等於行程先後。不可編造地址、座標、營業時間、價格、庫存或順路分鐘數。
回傳繁體中文欄位內容，專有名詞保留原文。`;

function anchored(span: string, input: InboxInput): boolean {
  if (/^image:[1-9][0-9]*$/.test(span)) {
    const index = Number(span.slice(6));
    return index <= input.imageBase64.length;
  }
  return input.rawText.includes(span) || (input.publicText ?? "").includes(span) || (input.title ?? "").includes(span);
}

// 模型可能只引用店名；連同原文前後一起檢查，避免把「不要去／避雷」存成想去。
function negativeContext(span: string, input: InboxInput): boolean {
  if (span.startsWith("image:")) return false;
  const text = input.rawText.includes(span) ? input.rawText : (input.publicText ?? "").includes(span) ? input.publicText! : input.title ?? "";
  for (let start = text.indexOf(span); start >= 0; start = text.indexOf(span, start + span.length)) {
    const before = text.slice(Math.max(0, start - 40), start).split(/[，,。！？!?；;\n]/).at(-1) ?? "";
    const after = text.slice(start + span.length, start + span.length + 40).split(/[，,。！？!?；;\n]/)[0] ?? "";
    const context = before + span + after;
    if (/不要去|別去|不想去|沒去|未去|不推薦|避雷|踩雷|已歇業|倒閉|不要買|別買|不想買|don't go|do not go|not recommend|avoid|skip/i.test(context)) return true;
  }
  return false;
}

// 與實際送進模型的範圍一致，截斷之外的原文不能被拿來冒充模型看到的證據。
export function modelInput(input: InboxInput): InboxInput {
  return { ...input, rawText: input.rawText.slice(0, 20000), publicText: input.publicText?.slice(0, 5000) ?? null,
    imageBase64: input.imageBase64.slice(0, 10) };
}

function imageSource(span: string, input: InboxInput): string {
  if (!/^image:[1-9][0-9]*$/.test(span)) return span;
  const index = Number(span.slice(6)) - 1;
  const first = input.imageBase64.indexOf(input.imageBase64[index]);
  return first >= 0 ? `image:${first + 1}` : span;
}

function screenshotControl(name: string): boolean {
  return /^(?:串文|作者|最相關|查看動態|Instagram|Threads|Trip\.com|\d{1,2}:\d{2}|[\d.]+萬?次瀏覽|回覆\s+\S+)$/i.test(name.trim());
}

// 模型偶爾把菜名當商品；只擋明確菜名，包裝與伴手禮證據必須屬於該項來源。
function diningClue(item: z.infer<typeof Item>): boolean {
  const name = item.display_name;
  const evidence = name + " " + (item.source_span.startsWith("image:") ? "" : item.source_span);
  if (/料理包|調理包|調理袋|即食|泡麵|方便麵|速食麵|冷凍|真空|袋裝|盒裝|瓶裝|包裝|伴手禮|禮盒|乾拌麵|沖泡|拉麵包|乾麵條/.test(evidence)) return false;
  return /(?:冷麵|冷麪|拌飯|人[蔘參]雞|蔘雞湯|參雞湯|水芹菜烤肉|水芹菜煎餅|水波蛋寬麵|嫩切豬肉|돼지곰탕|냉면|삼계탕)$/.test(name.trim());
}

export function validateResult(input: InboxInput, raw: unknown): ValidatedResult {
  input = modelInput(input);
  const parsed = InboxResult.parse(raw);
  const seen = new Set<string>();
  const items = parsed.items.filter((item) => anchored(item.source_span, input) &&
    !(item.source_span.startsWith("image:") && screenshotControl(item.display_name))).map((item) => {
    if (item.kind === "product" && diningClue(item)) {
      item = { ...item, kind: "place", confidence: "low", store_hint: null, store_evidence: null };
    }
    const source = item.source_span.toLocaleLowerCase();
    const name = item.display_name.toLocaleLowerCase();
    const imageEvidence = source.startsWith("image:");
    const textEvidence = !imageEvidence && source.includes(name);
    const ambiguous = /(?:或|可能|附近|哪家|分店不明)/.test(item.source_span);
    const storeEvidence = item.store_evidence?.trim() ?? null;
    const storeHint = item.kind === "product" && item.store_hint?.trim() && storeEvidence &&
      anchored(storeEvidence, input) && (storeEvidence.startsWith("image:") ||
        storeEvidence.toLocaleLowerCase().includes(item.store_hint.trim().toLocaleLowerCase()))
      ? item.store_hint.trim() : null;
    return {
      ...item,
      source_span: imageSource(item.source_span, input),
      store_hint: storeHint,
      store_evidence: storeHint ? storeEvidence : null,
      auto_archive: item.origin_type === "explicit" && item.confidence === "high" && (textEvidence || imageEvidence) &&
        !ambiguous && !negativeContext(item.source_span, input),
    };
  }).filter((item) => {
    // 只合併相同來源（包含位元組相同的重複圖片）與相同名稱／店家／日期；不跨貼文猜同店。
    const key = JSON.stringify([item.kind, item.display_name.trim().normalize("NFKC").toLowerCase(),
      item.source_span, item.store_hint, item.day_index]);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  const template_days = parsed.template_days.map((day) => ({
    ...day,
    stops: day.stops.filter((stop) => anchored(stop.source_span, input) && !negativeContext(stop.source_span, input)),
  })).filter((day) => anchored(day.source_span, input) && day.stops.length > 0);
  const kinds = new Set(items.map((item) => item.kind));
  const content_kind = template_days.length ? parsed.content_kind : kinds.size > 1 ? "mixed" :
    kinds.has("place") ? "recommendations" : kinds.has("product") ? "shopping" : parsed.content_kind;
  return { content_kind, items, template_days };
}

export async function organizeCapture(client: Anthropic, input: InboxInput, model = "claude-sonnet-5"):
  Promise<{ result: ValidatedResult; rawResult: z.infer<typeof InboxResult>; model: string;
    usage: { input_tokens: number; output_tokens: number } }> {
  input = modelInput(input);
  const content: Anthropic.Beta.Messages.BetaContentBlockParam[] = [];
  for (const data of input.imageBase64.slice(0, 10)) {
    content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data } });
  }
  content.push({ type: "text", text: JSON.stringify({ title: input.title, shared_text: input.rawText.slice(0, 20000),
    public_post_text: input.publicText?.slice(0, 5000) ?? null }) });
  const response = await client.beta.messages.parse({
    model,
    max_tokens: 8000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    thinking: { type: "adaptive" },
    output_config: { format: betaZodOutputFormat(InboxResult), effort: "medium" },
    system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content }],
  });
  if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens" || !response.parsed_output) {
    throw new Error("invalid_output");
  }
  return { result: validateResult(input, response.parsed_output), rawResult: response.parsed_output,
    model: response.model, usage: response.usage };
}
