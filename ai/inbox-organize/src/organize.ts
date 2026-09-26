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
輸出所有明確出現的地點、商品，以及來源明示的行程天數和順序。每項 source_span 必須是輸入文字的原文短句；若只來自第 1 張圖片，寫 image:1（依序類推）。
沒有店名、商品名稱或停靠點時，items 和 template_days 留空。「不要去／避雷／不要買」提到的對象不是收藏或行程停靠點。圖片中可讀到明確的店名或商品名稱時才給 high；只有區域與料理名稱（例如「聖水洞 水芹菜生牛肉拌飯」）時保留完整搜尋線索、給 low，不能當作已確認餐廳。地點有多個分店而來源未指明時，confidence 用 medium 或 low。
商品若有明確的購買店家、櫃位或店面招牌，填 store_hint（店名，不填地區）與 store_evidence（原文片段或 image:N）；沒有就填 null。可把「IVYNYU LAB 的墨鏡」拆為商品「墨鏡」與店家線索「IVYNYU LAB」，但不要把 Aesop 整個品牌誤當成特定門市，也不要宣稱有庫存。
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

export function validateResult(input: InboxInput, raw: unknown): ValidatedResult {
  const parsed = InboxResult.parse(raw);
  const items = parsed.items.filter((item) => anchored(item.source_span, input)).map((item) => {
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
      store_hint: storeHint,
      store_evidence: storeHint ? storeEvidence : null,
      auto_archive: item.origin_type === "explicit" && item.confidence === "high" && (textEvidence || imageEvidence) &&
        !ambiguous && !negativeContext(item.source_span, input),
    };
  });
  const template_days = parsed.template_days.map((day) => ({
    ...day,
    stops: day.stops.filter((stop) => anchored(stop.source_span, input) && !negativeContext(stop.source_span, input)),
  })).filter((day) => anchored(day.source_span, input) && day.stops.length > 0);
  return { content_kind: parsed.content_kind, items, template_days };
}

export async function organizeCapture(client: Anthropic, input: InboxInput, model = "claude-sonnet-5"):
  Promise<{ result: ValidatedResult; model: string }> {
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
  return { result: validateResult(input, response.parsed_output), model: response.model };
}
