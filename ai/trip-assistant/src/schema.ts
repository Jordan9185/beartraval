// Contract for the trip assistant (spec §3.7, plan WP10).
//
// The assistant only sees one trip's data, and route minutes only come from
// route_facts the app computed on device. It can suggest adding a confirmed
// Saved place to a day; the app turns that into a change proposal that the
// user confirms (WP5). It never writes anything itself.

import * as z from "zod/v4";

export const TripContext = z.object({
  trip: z.object({ name: z.string(), start_date: z.string(), end_date: z.string(), time_zone: z.string() }),
  today: z.string().nullable(),
  days: z.array(
    z.object({
      id: z.string(),
      date: z.string(),
      transport_mode: z.enum(["walking", "transit", "driving"]),
      stops: z.array(
        z.object({
          id: z.string(),
          label: z.string(),
          start_time: z.string().nullable(),
          fixed: z.boolean(),
          kind: z.enum(["standard", "purchase"]),
          place_confirmed: z.boolean(),
        }),
      ),
    }),
  ),
  saved: z.array(
    z.object({
      id: z.string(),
      label: z.string(),
      category: z.enum(["eat", "cafe", "shop", "place", "other"]),
      place_confirmed: z.boolean(),
      added_by: z.string(),
      interested: z.array(z.string()),
    }),
  ),
  shopping: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      status: z.enum(["unscheduled", "scheduled", "purchased"]),
      planned_date: z.string().nullable(),
      planned_store: z.string().nullable(),
      // "Possible merchants" only; stock is always unknown.
      merchants: z.array(z.object({ name: z.string(), evidence: z.string() })),
    }),
  ),
  // Computed by the app with Apple Maps; null minutes means it could not be estimated.
  route_facts: z.array(
    z.object({
      id: z.string(),
      saved_id: z.string(),
      day_id: z.string(),
      added_travel_minutes: z.number().nullable(),
      added_dwell_minutes: z.number(),
      fixed_conflict_minutes: z.number().nullable(),
    }),
  ),
});

export const Citation = z.object({
  type: z.enum(["stop", "saved", "shopping", "route_fact"]),
  id: z.string(),
});

export const AssistantAnswer = z.object({
  // Traditional Chinese answer shown to the user.
  answer: z.string(),
  // True when the trip data does not contain what the question needs.
  cannot_determine: z.boolean(),
  citations: z.array(Citation),
  // Optional suggestion to add a confirmed Saved place to a day. The app
  // recomputes the numbers and asks the user to confirm before anything changes.
  proposal: z
    .object({
      day_id: z.string(),
      saved_id: z.string(),
      reason: z.string(),
    })
    .nullable(),
});

export type TripContext = z.infer<typeof TripContext>;
export type Citation = z.infer<typeof Citation>;
export type AssistantAnswer = z.infer<typeof AssistantAnswer>;
