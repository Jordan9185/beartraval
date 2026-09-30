import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, chmod, rm, readdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { infer, codexClient, codexSchema, imageOnlySchema, WaitingError, isolatedEnvironment, verifyLogin, type Config } from "../src/codex.ts";
import { publicAddress, pageText, readPublicPage } from "../src/sources.ts";

async function fixture(run: (config: Config) => Promise<void>) {
  const runtime = await mkdtemp(join(tmpdir(), "bt-worker-test-"));
  const codex = join(runtime, "mock-codex");
  await writeFile(codex, `#!/usr/bin/env node
const fs = require('fs');
if (process.argv[2] === 'login') { console.error('Logged in using ChatGPT'); process.exit(0); }
const args = process.argv.slice(2);
fs.writeFileSync(${JSON.stringify(join(runtime, "args.json"))}, JSON.stringify(args));
let input = ''; process.stdin.on('data', s => input += s); process.stdin.on('end', () => {
 fs.writeFileSync(args[args.indexOf('--output-last-message') + 1], JSON.stringify({ days: 5 }));
 console.log(JSON.stringify({type:'turn.completed',usage:{input_tokens:20,output_tokens:5}}));
});\n`, { mode: 0o700 });
  await chmod(codex, 0o700);
  try { await run({ runtime, codex, model: "gpt-5.6-luna", endpoint: "https://example.com", token: "test-only" }); }
  finally { await rm(runtime, { recursive: true, force: true }); }
}

test("只保留必要環境，不繼承 API 或工作憑證", () => {
  process.env.OPENAI_API_KEY = "must-not-pass";
  process.env.ANTHROPIC_API_KEY = "must-not-pass";
  process.env.PERSONAL_AI_WORKER_TOKEN = "must-not-pass";
  const env = isolatedEnvironment();
  assert.equal(env.OPENAI_API_KEY, undefined); assert.equal(env.ANTHROPIC_API_KEY, undefined);
  assert.equal(env.PERSONAL_AI_WORKER_TOKEN, undefined);
  delete process.env.OPENAI_API_KEY; delete process.env.ANTHROPIC_API_KEY; delete process.env.PERSONAL_AI_WORKER_TOKEN;
});
test("結構輸出、圖片與用量接回，暫存素材清除且禁止命令工具", () => fixture(async config => {
  const result = await infer(config, "東京五日", { type: "object" }, [Buffer.from("fake-image").toString("base64")]);
  assert.equal(result.value.days, 5); assert.equal(result.usage.input_tokens, 20);
  assert.ok(!(await readdir(config.runtime)).some(name => name.startsWith("request-")));
  const args = JSON.parse(await readFile(join(config.runtime, "args.json"), "utf8"));
  assert.ok(args.includes('forced_login_method="chatgpt"')); assert.ok(args.includes("features.shell_tool=false"));
  assert.ok(args.includes('--ignore-user-config')); assert.ok(args.includes('web_search="disabled"'));
}));
test("付費 API 登入不執行模型，也不靜默切換", () => fixture(async config => {
  await writeFile(config.codex, "#!/usr/bin/env node\nconsole.log('Logged in using an API key');\n", { mode: 0o700 });
  await assert.rejects(infer(config, "test", {}, []), (error: unknown) =>
    error instanceof WaitingError && error.reason === "personal_ai_login");
}));
test("串流接頭沿用原模組需要的最終結果與進度", () => fixture(async config => {
  const client = codexClient(config);
  const stream = client.beta.messages.stream({ system: "整理", messages: [{ role: "user", content: "東京" }],
    output_config: { format: { schema: { type: "object" } } } });
  let snapshot = "";
  stream.on("text", (_delta, value) => snapshot = value);
  const result = await stream.finalMessage();
  assert.equal(result.model, "codex/gpt-5.6-luna"); assert.equal(JSON.parse(snapshot).days, 5);
}));
test("來源不讀本機、私網、metadata、非 HTTPS 或帶憑證網址", async () => {
  for (const ip of ["127.0.0.1", "10.0.1.2", "172.16.1.1", "192.168.0.1", "169.254.169.254", "100.64.1.2", "::1", "fc00::1", "::ffff:127.0.0.1"]) {
    assert.equal(publicAddress(ip), false, ip);
  }
  assert.equal(publicAddress("8.8.8.8"), true);
  for (const url of ["http://example.com", "https://user:pass@example.com", "https://example.com:8443", "https://127.0.0.1"]) {
    await assert.rejects(readPublicPage(url), /unsafe_source/);
  }
});
test("來源只使用下載的網頁文字，排除 script 和樣式", () => {
  assert.equal(pageText('<script>假店名</script><style>假地址</style><p>東京 &amp; &#x6DFA;草</p>'), '東京 & 淺草');
});
test("轉換不相容的 uri format，保留原 schema 和必要欄位", () => {
  const schema = { type: "object", required: ["url"], additionalProperties: false,
    properties: { url: { anyOf: [{ type: "string", format: "uri" }, { type: "null" }] } } };
  const converted = codexSchema(schema);
  assert.equal(converted.properties.url.anyOf[0].format, undefined);
  assert.equal(schema.properties.url.anyOf[0].format, "uri");
  assert.deepEqual(converted.required, ["url"]);
  assert.equal(converted.additionalProperties, false);
});
test("純圖片來源限於實際附件編號，避免 OCR 文字被當成不存在的文字輸入而刪掉", () => {
  const schema = { properties: { items: { items: { properties: {
    source_span: { type: "string" }, store_evidence: { type: "string" },
  } } } } };
  const result = imageOnlySchema(schema, 2);
  assert.deepEqual(result.properties.items.items.properties.source_span.enum, ["image:1", "image:2"]);
  assert.equal(result.properties.items.items.properties.store_evidence.anyOf[1].type, "null");
  assert.equal((schema.properties.items.items.properties.source_span as any).enum, undefined);
});

test("登入檢查逾時或無法執行時只算等待，不冒稱需要重新登入", () => fixture(async config => {
  await writeFile(config.codex, "#!/usr/bin/env node\nsetTimeout(() => {}, 60000);\n", { mode: 0o700 });
  const started = Date.now();
  assert.throws(() => verifyLogin({ ...config, codex: join(config.runtime, "missing-codex") }),
    (error: unknown) => error instanceof WaitingError && error.reason === "personal_ai_waiting");
  assert.ok(Date.now() - started < 5000);
}));
test("明確未登入才要求重新登入；成功結果短暫沿用", () => fixture(async config => {
  await writeFile(config.codex, "#!/usr/bin/env node\nconsole.log('Not logged in'); process.exit(1);\n", { mode: 0o700 });
  assert.throws(() => verifyLogin(config), (error: unknown) => error instanceof WaitingError && error.reason === "personal_ai_login");
  await writeFile(config.codex, "#!/usr/bin/env node\nconsole.error('Logged in using ChatGPT');\n", { mode: 0o700 });
  verifyLogin(config, 1_000_000);
  await writeFile(config.codex, "#!/usr/bin/env node\nprocess.exit(1);\n", { mode: 0o700 });
  verifyLogin(config, 1_000_000 + 60_000);
  assert.throws(() => verifyLogin(config, 1_000_000 + 6 * 60_000), (error: unknown) =>
    error instanceof WaitingError && error.reason === "personal_ai_login");
}));
