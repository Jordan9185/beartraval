import Anthropic from "@anthropic-ai/sdk";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { z } from "zod/v4";
import { organizeCapture } from "../src/organize.ts";

// 只接受本機清單；原圖、模型結果均留在使用者指定的忽略目錄，不寫入正式收件匣。
const Manifest = z.array(z.object({
  id: z.string().regex(/^[a-z0-9_-]+$/),
  images: z.array(z.string()).min(1).max(10),
  rawText: z.string().default(""),
  reviewNotes: z.string().default(""),
})).min(1);

async function main() {
  const [manifestPath, outputPath] = process.argv.slice(2);
  if (!manifestPath || !outputPath) throw new Error("請指定評測清單與本機輸出資料夾");
  const samples = Manifest.parse(JSON.parse(await readFile(resolve(manifestPath), "utf8")));
  if (new Set(samples.map((sample) => sample.id)).size !== samples.length) throw new Error("樣本 ID 不可重複");
  if (!process.env.ANTHROPIC_API_KEY) throw new Error("缺少 ANTHROPIC_API_KEY 環境設定，尚未呼叫模型");
  const client = new Anthropic({ timeout: 90_000, maxRetries: 0 });
  const output = resolve(outputPath);
  await mkdir(output, { recursive: true });
  for (const sample of samples) {
    const images = await Promise.all(sample.images.map(async (path) => {
      const bytes = await readFile(resolve(path));
      if (bytes.length > 2_000_000 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
        throw new Error("素材須先經 App 的縮圖流程輸出為 2 MB 以內 JPEG");
      }
      return bytes.toString("base64");
    }));
    const startedAt = new Date().toISOString();
    const start = performance.now();
    const outcome = await organizeCapture(client, { title: null, rawText: sample.rawText, imageBase64: images },
      process.env.ANTHROPIC_MODEL || "claude-sonnet-5");
    await writeFile(join(output, `${sample.id}.json`), JSON.stringify({ id: sample.id, startedAt,
      elapsedMs: Math.round(performance.now() - start), ...outcome,
      reviewNotes: sample.reviewNotes, acceptance: "待人工逐項核對；執行成功不等於辨識正確" }, null, 2));
    console.log(`${sample.id}：已取得模型結果，待人工核對`);
  }
}

main().catch((error: unknown) => {
  // 避免 SDK 錯誤物件帶出請求、驗證資訊或完整原始素材。
  console.error(error instanceof Anthropic.APIError ? `模型請求失敗（HTTP ${error.status ?? "未知"}）` :
    error instanceof Error && /^(請指定|樣本|缺少|素材須)/.test(error.message) ? error.message : "評測未完成，請檢查清單與本機檔案");
  process.exitCode = 1;
});
