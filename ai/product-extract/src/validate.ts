// Checks the model's product list before the app shows it. Anything doubtful is
// downgraded to low confidence rather than silently accepted.

import type { ExtractInput, ExtractResult } from "./schema.ts";

export const MAX_PRODUCTS = 10;
const MAX_FIELD = 200;
const MAX_WARNINGS = 10;

export interface ValidationIssue {
  path: string;
  issue: string;
}

const squash = (s: string) => s.replace(/\s+/g, " ").trim().toLowerCase();

export function validateProducts(input: ExtractInput, draft: ExtractResult): { result: ExtractResult; issues: ValidationIssue[] } {
  const issues: ValidationIssue[] = [];
  const caption = squash([input.text, input.url ?? ""].join(" "));
  const products = draft.products
    .map((p) => ({
      ...p,
      name: p.name.trim().slice(0, MAX_FIELD),
      brand: p.brand?.trim().slice(0, MAX_FIELD) || null,
      variant: p.variant?.trim().slice(0, MAX_FIELD) || null,
      search_query: p.search_query?.trim().slice(0, MAX_FIELD) || null,
      store_hint: p.store_hint?.trim().slice(0, MAX_FIELD) || null,
      store_evidence: p.store_evidence?.trim().slice(0, MAX_FIELD) || null,
    }))
    .filter((p, i) => {
      if (p.name.length === 0) issues.push({ path: `products[${i}]`, issue: "empty name dropped" });
      return p.name.length > 0;
    });

  products.forEach((p, i) => {
    // Caption evidence must really be in the caption; otherwise it was invented
    // or planted, and the user should look twice.
    if (p.evidence !== "image" && !caption.includes(squash(p.evidence))) {
      issues.push({ path: `products[${i}].evidence`, issue: "evidence not found in caption" });
      p.confidence = "low";
    }
    if (p.evidence === "image" && !input.imageBase64) {
      issues.push({ path: `products[${i}].evidence`, issue: "image evidence but no image" });
      p.confidence = "low";
    }
    if (p.store_hint) {
      const source = p.store_evidence;
      const anchored = source === "image" ? Boolean(input.imageBase64) :
        Boolean(source && caption.includes(squash(source)) && squash(source).includes(squash(p.store_hint)));
      if (!anchored) {
        issues.push({ path: `products[${i}].store_hint`, issue: "store hint has no anchored evidence" });
        p.store_hint = null;
        p.store_evidence = null;
      }
    } else {
      p.store_evidence = null;
    }
  });

  if (products.length > MAX_PRODUCTS) issues.push({ path: "products", issue: `${products.length} products, kept ${MAX_PRODUCTS}` });
  return {
    result: {
      products: products.slice(0, MAX_PRODUCTS),
      warnings: draft.warnings.slice(0, MAX_WARNINGS).map((w) => (w.length > 300 ? `${w.slice(0, 300)}…` : w)),
    },
    issues,
  };
}
