import { readFile, mkdir, writeFile, rename, rm, readdir } from "node:fs/promises";
import { join } from "node:path";
import { processTask } from "./tasks.ts";
import { verifyLogin, WaitingError, type Config } from "./codex.ts";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function main() {
  const config: Config = JSON.parse(await readFile(process.argv[2], "utf8"));
  await mkdir(config.runtime, { recursive: true, mode: 0o700 });
  // 不保存推論原文；上次中斷留下的圖片與暫存格式在下次啟動清除。
  for (const name of await readdir(config.runtime)) if (name.startsWith("request-")) {
    await rm(join(config.runtime, name), { recursive: true, force: true });
  }
  const api = async (body: unknown): Promise<any> => {
    const response = await fetch(config.endpoint, { method: "POST", headers: {
      "Content-Type": "application/json", "X-Personal-AI-Token": config.token,
    }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`gateway_${response.status}`);
    return response.json();
  };

  for (;;) {
    try {
      for (const name of await readdir(config.runtime)) {
        if (!name.startsWith("cache-") || !name.endsWith(".json")) continue;
        const path = join(config.runtime, name);
        try {
          const cached = JSON.parse(await readFile(path, "utf8"));
          if (Date.now() - cached.created >= 600_000) await rm(path, { force: true });
        } catch { await rm(path, { force: true }); }
      }
      // 每筆工作各自保留待寫回結果；即使斷線超過租約，領回時也不再次推論。
      for (const name of await readdir(config.runtime)) {
        if (!name.endsWith(".result.json")) continue;
        const path = join(config.runtime, name);
        const pending = JSON.parse(await readFile(path, "utf8"));
        const saved = await api(pending);
        if (saved.accepted || saved.terminal) await rm(path, { force: true });
      }
      verifyLogin(config);
      const { job } = await api({ action: "claim" });
      if (!job) { await sleep(8000); continue; }
      console.log(JSON.stringify({ event: "started", id: job.id, kind: job.kind }));
      const pendingFile = join(config.runtime, `${job.id}.result.json`);
      const controller = new AbortController();
      let leaseLost = false;
      const heartbeat = setInterval(() => {
        api({ action: "heartbeat", job_id: job.id, lease: job.lease }).then((result) => {
          if (!result.accepted) { leaseLost = true; controller.abort(); }
        }).catch(() => { /* 暫時斷線仍保留已生成結果；後端租約決定是否接受。 */ });
      }, 25_000);
      try {
        let result;
        try {
          let cached;
          try { cached = JSON.parse(await readFile(pendingFile, "utf8")); } catch { /* 尚未生成。 */ }
          result = cached?.result ?? await processTask(config, job, controller.signal);
        }
        catch (error) {
          if (error instanceof WaitingError) {
            await api({ action: "defer", job_id: job.id, lease: job.lease, reason: error.reason });
            console.log(JSON.stringify({ event: "waiting", reason: error.reason }));
            await sleep(60_000); continue;
          }
          // 只記錯誤類型與 Codex 錯誤輸出中的錯誤行末段，不記原文、提示詞或憑證，供之後排查。
          const cause = error instanceof Error ? String((error as Error & { cause?: unknown }).cause ?? "") : "";
          console.log(JSON.stringify({ event: "task_error", id: job.id, kind: job.kind,
            error: error instanceof Error ? error.message : "unknown",
            detail: cause.split("\n").filter((line) => /error|fail|timeout|denied|invalid/i.test(line)).join(" | ").slice(-400) }));
          result = { status: "failed", reason: error instanceof Error &&
            ["no_verified_suggestions", "incomplete_suggestions", "invalid_output"].includes(error.message)
            ? error.message : "personal_ai_error" };
        }
        if (leaseLost) continue;
        const completion = { action: "complete", job_id: job.id, lease: job.lease, result, model: result.model ?? `codex/${config.model}` };
        await writeFile(`${pendingFile}.tmp`, JSON.stringify(completion), { mode: 0o600 });
        await rename(`${pendingFile}.tmp`, pendingFile);
        const saved = await api(completion);
        if (saved.accepted || saved.terminal) await rm(pendingFile, { force: true });
        console.log(JSON.stringify({ event: "finished", id: job.id, kind: job.kind,
          status: result.status, accepted: saved.accepted }));
      } finally { clearInterval(heartbeat); }
    } catch (error) {
      console.log(JSON.stringify({ event: "waiting", reason: error instanceof WaitingError ? error.reason : "connection" }));
      await sleep(30_000);
    }
  }
}
main().catch(() => { console.error("個人 AI 工作程式無法啟動，請檢查本機設定。"); process.exitCode = 1; });
