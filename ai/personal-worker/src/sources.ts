import { lookup } from "node:dns/promises";
import { request } from "node:https";
import { isIP } from "node:net";

// 模型給的網址是不可信輸入；只讀取公開 HTTPS 網頁，DNS 解析後固定連線 IP。
export function publicAddress(address: string): boolean {
  if (isIP(address) === 6) return /^[23][0-9a-f]{3}:/i.test(address) && !/^2001:(?:db8|0):/i.test(address);
  if (isIP(address) !== 4) return false;
  const [a, b] = address.split(".").map(Number);
  return a > 0 && a !== 10 && a !== 127 && a < 224 &&
    !(a === 169 && b === 254) && !(a === 172 && b >= 16 && b <= 31) &&
    !(a === 192 && (b === 168 || b === 0)) && !(a === 100 && b >= 64 && b <= 127) &&
    !(a === 198 && (b === 18 || b === 19));
}
export function pageText(html: string): string {
  return html.replace(/<(script|style|noscript)\b[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<[^>]+>/g, " ").replace(/&#(x[0-9a-f]+|[0-9]+);/gi, (_, n) => {
      const code = n[0].toLowerCase() === "x" ? parseInt(n.slice(1), 16) : Number(n);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : " ";
    }).replace(/&(amp|quot|apos|nbsp|lt|gt);/g, (_, name) =>
      ({ amp: "&", quot: '"', apos: "'", nbsp: " ", lt: "<", gt: ">" })[name] ?? " ")
    .replace(/\s+/g, " ").trim();
}
export async function readPublicPage(raw: string, redirects = 0): Promise<{ url: string; title: string; text: string }> {
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443") || redirects > 3) {
    throw new Error("unsafe_source");
  }
  const addresses = await lookup(url.hostname, { all: true });
  if (!addresses.length || addresses.some((entry) => !publicAddress(entry.address))) throw new Error("unsafe_source");
  const chosen = addresses[0];
  const response = await new Promise<{ status: number; location?: string; html: string }>((resolve, reject) => {
    const req = request(url, { headers: { "User-Agent": "BearTravel/0.1 (personal travel research)", Accept: "text/html" },
      lookup: ((_host: string, options: any, callback: any) => options.all
        ? callback(null, [chosen]) : callback(null, chosen.address, chosen.family)) as any, timeout: 12_000 }, (res) => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume(); resolve({ status: res.statusCode, location: res.headers.location, html: "" }); return;
      }
      if (res.statusCode !== 200 || !/text\/html|text\/plain/i.test(res.headers["content-type"] ?? "")) {
        res.resume(); reject(new Error("source_unavailable")); return;
      }
      const chunks: Buffer[] = []; let length = 0;
      res.on("data", (chunk: Buffer) => {
        length += chunk.length;
        if (length > 4_000_000) req.destroy(new Error("source_too_large")); else chunks.push(chunk);
      });
      res.on("error", reject);
      res.on("end", () => resolve({ status: 200, html: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("timeout", () => req.destroy(new Error("source_timeout")));
    req.on("error", reject); req.end();
  });
  if (response.location) return readPublicPage(new URL(response.location, url).href, redirects + 1);
  return { url: url.href, title: pageText(response.html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? ""),
    text: pageText(response.html).slice(0, 300_000) };
}
