// Output contract for product extraction from a shared post (spec §3.6).
//
// Only a draft: the user picks which products go on the shopping list and can
// edit every field. A quoted store is a clue, never confirmed availability.

import * as z from "zod/v4";

export const ExtractedProduct = z.object({
  // Product name as the post shows it (any language); what goes on the list.
  name: z.string(),
  brand: z.string().nullable(),
  // Colour, size, shade, model number, if shown.
  variant: z.string().nullable(),
  // A search phrase for finding it later, in the product's own language.
  search_query: z.string().nullable(),
  // Where in the post it came from: quoted caption text, or "image".
  evidence: z.string(),
  // A named shop or counter explicitly shown in the post; never inventory proof.
  store_hint: z.string().nullable(),
  store_evidence: z.string().nullable(),
  confidence: z.enum(["high", "medium", "low"]),
});

export const ExtractResult = z.object({
  products: z.array(ExtractedProduct),
  warnings: z.array(z.string()),
});

export type ExtractedProduct = z.infer<typeof ExtractedProduct>;
export type ExtractResult = z.infer<typeof ExtractResult>;

export interface ExtractInput {
  // Caption, title and any other text the share sheet provided.
  text: string;
  url: string | null;
  // Downscaled JPEG, base64 without the data: prefix.
  imageBase64: string | null;
}
