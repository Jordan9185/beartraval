// 只讀公開 Threads 頁面的 Open Graph 摘要；不登入、不讀私人內容或任意網址。
export type PublicPost = { text: string; title: string | null; resolvedURL: string };

const MAX_HTML_BYTES = 2_000_000;
const THREADS_HOSTS = new Set(["threads.com", "www.threads.com", "threads.net", "www.threads.net"]);

function allowed(url: URL): boolean {
  return url.protocol === "https:" && THREADS_HOSTS.has(url.hostname.toLowerCase());
}

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, (_, entity: string) => {
    const key = entity.toLowerCase();
    if (key.startsWith("#x")) return String.fromCodePoint(Number.parseInt(key.slice(2), 16));
    if (key.startsWith("#")) return String.fromCodePoint(Number.parseInt(key.slice(1), 10));
    return ({ amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", nbsp: " " } as Record<string, string>)[key] ?? "";
  });
}

export function publicMetadata(html: string): { title: string | null; text: string | null } {
  const values = new Map<string, string>();
  for (const tag of html.match(/<meta\b[^>]*>/gi) ?? []) {
    const attributes = new Map<string, string>();
    for (const match of tag.matchAll(/([\w:-]+)\s*=\s*(["'])([\s\S]*?)\2/g)) {
      attributes.set(match[1]!.toLowerCase(), decodeEntities(match[3]!));
    }
    const key = (attributes.get("property") ?? attributes.get("name"))?.toLowerCase();
    if (key && attributes.has("content")) values.set(key, attributes.get("content")!);
  }
  const text = values.get("og:description") ?? values.get("description") ?? null;
  return {
    title: values.get("og:title")?.trim().slice(0, 300) || null,
    text: text?.trim().slice(0, 5000) || null,
  };
}

export async function publicThreadsPost(source: string, fetcher: typeof fetch = fetch): Promise<PublicPost | null> {
  let url: URL;
  try { url = new URL(source); } catch { return null; }
  if (!allowed(url)) return null;
  for (let redirects = 0; redirects < 3; redirects++) {
    const response = await fetcher(url, { redirect: "manual", signal: AbortSignal.timeout(6000),
      headers: { Accept: "text/html" } });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location) return null;
      url = new URL(location, url);
      if (!allowed(url)) return null;
      continue;
    }
    if (!response.ok || !response.headers.get("content-type")?.toLowerCase().includes("text/html")) return null;
    if (Number(response.headers.get("content-length") ?? 0) > MAX_HTML_BYTES) return null;
    if (!response.body) return null;
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.length;
      if (size > MAX_HTML_BYTES) { await reader.cancel(); return null; }
      chunks.push(next.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const meta = publicMetadata(new TextDecoder().decode(bytes));
    if (!meta.text) return null;
    return { text: meta.text, title: meta.title, resolvedURL: url.href };
  }
  return null;
}
