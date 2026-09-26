import assert from "node:assert/strict";
import test from "node:test";
import { publicMetadata, publicThreadsPost } from "../src/public-post.ts";

test("公開 Threads 摘要可處理分享短連結轉址與 HTML entity", async () => {
  const html = '<meta property="og:title" content="作者 on Threads"/><meta property="og:description" content="無垢屋人蔘雞 &amp; 聖水洞"/>';
  const called: string[] = [];
  const fetcher = (async (input: string | URL | Request) => {
    const url = String(input);
    called.push(url);
    return called.length === 1
      ? new Response(null, { status: 302, headers: { location: "https://www.threads.com/@comeswind/post/abc" } })
      : new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
  }) as typeof fetch;
  const post = await publicThreadsPost("https://www.threads.com/share/_77GV9nCg/", fetcher);
  assert.equal(post?.text, "無垢屋人蔘雞 & 聖水洞");
  assert.equal(post?.resolvedURL, "https://www.threads.com/@comeswind/post/abc");
  assert.equal(called.length, 2);
});

test("轉址到非 Threads 網域不會讀取", async () => {
  let calls = 0;
  const fetcher = (async () => {
    calls++;
    return new Response(null, { status: 302, headers: { location: "https://127.0.0.1/private" } });
  }) as typeof fetch;
  assert.equal(await publicThreadsPost("https://www.threads.com/share/x", fetcher), null);
  assert.equal(calls, 1);
  assert.equal(await publicThreadsPost("https://example.com/post", fetcher), null);
  assert.equal(calls, 1);
});

test("沒有公開摘要時不猜貼文內容", () => {
  assert.equal(publicMetadata("<html><title>Threads</title></html>").text, null);
});

test("Threads 屬性內的換行與數字字元實體仍可讀取", () => {
  const html = '<meta property="og:description" content="&#x7121;&#x57a2;&#x5c4b;\n&#x8056;&#x6c34;&#x6d1e;" />';
  assert.equal(publicMetadata(html).text, "無垢屋\n聖水洞");
});
