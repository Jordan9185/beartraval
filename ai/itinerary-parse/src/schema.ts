// Output contract for itinerary text parsing (spec §5.1, plan §3.2).
//
// The model only produces a draft: there is deliberately no "committed" or
// "confirmed" state here. Every stop goes through the Confirm Places screen, and
// place facts (address, hours) come from the Place lookup, never from the model.

import * as z from "zod/v4";

export const StopCategory = z.enum([
  "eat",
  "cafe",
  "shop",
  "place",
  "lodging",
  "transport",
  "other",
]);

export const ConfirmationReason = z.enum([
  // A chain or common name with no branch/area to pick one location (AC-01).
  "ambiguous_branch",
  // The text names something, but it may not be a findable place.
  "unknown_place",
  // Which day this belongs to is unclear or outside the trip dates.
  "ambiguous_date",
  // The time is vague ("afternoon", "around noon") or conflicting.
  "ambiguous_time",
]);

export const ParsedStop = z.object({
  // Verbatim span of the input this stop came from, for side-by-side review.
  source_excerpt: z.string(),
  // Name as written in the text (any language); null if no place is named.
  place_name: z.string().nullable(),
  // Branch or area hint from the text ("明洞", "Seongsu", "広島駅"), if any.
  branch_hint: z.string().nullable(),
  // City, town or island in English ("Seoul", "Onomichi"); scopes the map search.
  city: z.string().nullable(),
  // ISO 3166-1 alpha-2 ("KR", "JP") of the place; picks the local map app when
  // Apple Maps can't find it.
  country_code: z.string().nullable(),
  // Query for the place lookup in the place's local language, e.g. "마뗑킴 성수";
  // null for transport legs.
  search_query: z.string().nullable(),
  category: StopCategory,
  // 24h "HH:MM" local time, or null when no time is given.
  start_time: z.string().nullable(),
  end_time: z.string().nullable(),
  // True when the time is inferred from vague words rather than stated.
  time_is_approximate: z.boolean(),
  // True for flights, trains, ferries with a departure time, reservations,
  // timed tickets: things the user probably cannot move.
  fixed_suspected: z.boolean(),
  fixed_reason: z.string().nullable(),
  confidence: z.enum(["high", "medium", "low"]),
  needs_confirmation: z.array(ConfirmationReason),
});

export const ParsedDay = z.object({
  // ISO date within the trip, or null when the day can't be determined.
  date: z.string().nullable(),
  // How the text labelled the day ("Day 2", "10/3", "週五"), verbatim.
  day_label: z.string().nullable(),
  stops: z.array(ParsedStop),
});

export const ParseResult = z.object({
  days: z.array(ParsedDay),
  // Cities the itinerary appears to cover, most likely first; user confirms.
  city_candidates: z.array(z.string()),
  // Things the user should know that are not stops (e.g. "no dates found").
  warnings: z.array(z.string()),
});

export type StopCategory = z.infer<typeof StopCategory>;
export type ConfirmationReason = z.infer<typeof ConfirmationReason>;
export type ParsedStop = z.infer<typeof ParsedStop>;
export type ParsedDay = z.infer<typeof ParsedDay>;
export type ParseResult = z.infer<typeof ParseResult>;

export interface ParseInput {
  tripStart: string; // YYYY-MM-DD
  tripEnd: string; // YYYY-MM-DD
  timeZone: string; // IANA, e.g. "Asia/Seoul"
  rawText: string;
}
