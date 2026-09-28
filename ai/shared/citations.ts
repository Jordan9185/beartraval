// 純資料引用解析，不依賴任一 AI 模組的 SDK 安裝；各模組可獨立建置。
export type SearchCitation = { url: string; title: string | null; citedText: string };
export function citedSources(response: { content: unknown[] }): SearchCitation[] {
  const found = new Map<string, SearchCitation>();
  for (const value of response.content) {
    if (!value || typeof value !== "object") continue;
    const block = value as Record<string, unknown>;
    if (block.type !== "text" || !Array.isArray(block.citations)) continue;
    for (const value of block.citations) {
      if (!value || typeof value !== "object") continue;
      const citation = value as Record<string, unknown>;
      if (citation.type !== "web_search_result_location" || typeof citation.url !== "string" || typeof citation.cited_text !== "string") continue;
      try {
        const url = new URL(citation.url);
        if (url.protocol !== "https:") continue;
        const previous = found.get(url.href);
        const text = citation.cited_text;
        found.set(url.href, {
          url: url.href, title: typeof citation.title === "string" ? citation.title : previous?.title ?? null,
          citedText: previous ? previous.citedText.includes(text) ? previous.citedText : previous.citedText + "\n" + text : text,
        });
      } catch { /* 壞網址不作為證據。 */ }
    }
  }
  return Array.from(found.values()).slice(0, 15);
}
