import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { build } from "esbuild";

const first = "00000000-0000-0000-0000-00000000000a";
const second = "00000000-0000-0000-0000-00000000000b";
const outsider = "00000000-0000-0000-0000-00000000000c";
const lease = "00000000-0000-0000-0000-00000000000d";
const workerToken = "local-test-worker-token";
let handler: (request: Request) => Promise<Response>;
let jobs: any[] = [];
let calls: { name: string; params: any }[] = [];

// 真正的 Gateway 與排隊入口，僅以記憶體資料庫取代外部服務；不接觸個人登入。
class Query {
  filters: ((row: any) => boolean)[] = [];
  change?: any;
  single = false;
  sort?: string;
  select(_columns: string) { return this; }
  eq(key: string, value: any) { this.filters.push((row) => row[key] === value); return this; }
  in(key: string, values: any[]) { this.filters.push((row) => values.includes(row[key])); return this; }
  lte(key: string, value: any) { this.filters.push((row) => row[key] <= value); return this; }
  gt(key: string, value: any) { this.filters.push((row) => row[key] > value); return this; }
  or(_condition: string) {
    this.filters.push((row) => row.status === "queued" || (row.status === "running" && row.lease_until < new Date().toISOString()));
    return this;
  }
  order(key: string) { this.sort ??= key; return this; }
  limit(_limit: number) { return this; }
  update(change: any) { this.change = change; return this; }
  maybeSingle() { this.single = true; return this; }
  then(resolve: (value: any) => any, reject: (error: any) => any) {
    let rows = jobs.filter((row) => this.filters.every((filter) => filter(row)));
    if (this.sort) rows = rows.sort((a, b) => String(a[this.sort!]).localeCompare(String(b[this.sort!])));
    if (this.change) rows.forEach((row) => Object.assign(row, this.change));
    return Promise.resolve({ data: this.single ? rows[0] ?? null : rows, error: null }).then(resolve, reject);
  }
}
const admin = {
  auth: { getUser: async (token: string) => ({ data: { user: [first, second, outsider].includes(token) ? { id: token } : null } }) },
  from: () => new Query(),
  rpc: async (name: string, params: any) => {
    calls.push({ name, params });
    if (name === "enqueue_personal_ai") return { data: { id: crypto.randomUUID(), status: "queued" } };
    if (name === "claim_personal_ai") {
      const job = jobs.find((row) => row.owner_id === params.p_owner && row.status === "queued");
      if (job) Object.assign(job, { status: "running", lease });
      return { data: job ?? null };
    }
    if (name === "finish_personal_ai") {
      const job = jobs.find((row) => row.id === params.p_id && row.owner_id === params.p_owner && row.lease === params.p_lease && row.status === "running");
      if (job) Object.assign(job, { status: "completed", result: params.p_result });
      return { data: !!job };
    }
    return { data: true };
  },
};
Object.assign(globalThis, {
  __personalAITestAdmin: admin,
  Deno: {
    serve: (callback: typeof handler) => { handler = callback; },
    env: { get: (name: string) => ({ PERSONAL_AI_ALLOWED_USER_IDS: `${first},${second}`,
      PERSONAL_AI_WORKER_TOKEN: workerToken, SUPABASE_URL: "https://example.test", SUPABASE_SERVICE_ROLE_KEY: "test-only" })[name] },
  },
});
const bundled = await build({
  stdin: { contents: 'import "./supabase/functions/personal-ai/index.ts"; export { enqueuePersonalAI } from "./supabase/functions/_shared/personal-ai.ts";',
    resolveDir: new URL("../../../", import.meta.url).pathname },
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{ name: "test-database", setup(builder) {
    builder.onResolve({ filter: /^@supabase\/supabase-js$/ }, () => ({ path: "database", namespace: "test" }));
    builder.onLoad({ filter: /.*/, namespace: "test" }, () => ({ contents: "export const createClient = () => globalThis.__personalAITestAdmin;" }));
  } }],
});
const { enqueuePersonalAI } = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString("base64")}`);

const request = async (body: any, token = workerToken, app = false) => {
  const response = await handler(new Request("https://example.test/personal-ai", { method: "POST",
    headers: { "Content-Type": "application/json", [app ? "Authorization" : "X-Personal-AI-Token"]: app ? `Bearer ${token}` : token },
    body: JSON.stringify(body) }));
  return { status: response.status, body: await response.json() };
};
const job = (owner: string, created = "2026-01-01T00:00:00Z") => ({ id: crypto.randomUUID(), owner_id: owner,
  kind: "extract", status: "queued", lease, lease_until: "2099-01-01T00:00:00Z", available_at: created,
  created_at: created, updated_at: created, context: {}, input: {}, result: null });
beforeEach(() => { jobs = []; calls = []; });

test("兩個指定帳號均能排隊，第三個帳號不能呼叫模型", async () => {
  for (const owner of [first, second]) {
    assert.equal((await enqueuePersonalAI(`Bearer ${owner}`, "extract", { text: "測試" })).status, 202);
  }
  assert.deepEqual(calls.map((call) => call.params.p_owner), [first, second]);
  const rejected = await enqueuePersonalAI(`Bearer ${outsider}`, "extract", { text: "測試" });
  assert.equal((await rejected.json()).reason, "personal_ai_unavailable");
  assert.equal(calls.length, 2);
});

test("工作憑證不可省略；Mac 領取等待最久的獲准帳號", async () => {
  jobs = [job(first, "2026-01-02T00:00:00Z"), job(second), job(outsider, "2025-01-01T00:00:00Z")];
  assert.equal((await request({ action: "claim" }, "wrong")).status, 401);
  assert.equal(calls.length, 0);
  assert.equal((await request({ action: "claim" })).body.job.owner_id, second);
  assert.equal((await request({ action: "claim" })).body.job.owner_id, first);
  assert.equal((await request({ action: "claim" })).body.job, null);
  assert.equal(jobs[2].status, "queued");
});

test("完成結果依資料庫歸屬回寫第二個帳號，不採信請求的帳號", async () => {
  const target = job(second); target.status = "running"; jobs = [target];
  const response = await request({ action: "complete", owner_id: first, job_id: target.id, lease,
    result: { status: "extracted", products: [] }, model: "codex/gpt-5.6-luna" });
  assert.equal(response.body.accepted, true);
  assert.equal(calls[0].params.p_owner, second);
  assert.equal(target.status, "completed");
});

test("不允許完成或續租第三個帳號，錯誤租約也不能覆寫", async () => {
  const target = job(outsider); target.status = "running"; jobs = [target];
  const complete = { action: "complete", job_id: target.id, lease,
    result: { status: "extracted", products: [] }, model: "codex/gpt-5.6-luna" };
  assert.equal((await request(complete)).body.accepted, false);
  assert.equal((await request({ action: "heartbeat", job_id: target.id, lease })).body.accepted, false);
  assert.equal(calls.length, 0);
  target.owner_id = second;
  assert.equal((await request({ ...complete, lease: first })).body.accepted, false);
  assert.equal((await request({ action: "heartbeat", job_id: target.id, lease })).body.accepted, true);
});

test("手機只能查看自己的狀態與進度，分享同一部 Mac 不分享結果", async () => {
  const target = job(second); jobs = [target];
  assert.equal((await request({ action: "status", job_id: target.id }, first, true)).status, 404);
  assert.equal((await request({ action: "status", job_id: target.id }, second, true)).status, 200);
  assert.deepEqual((await request({ action: "activity" }, first, true)).body.jobs, []);
  assert.equal((await request({ action: "activity" }, second, true)).body.jobs.length, 1);
});
