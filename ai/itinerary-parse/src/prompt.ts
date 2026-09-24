import type { ParseInput } from "./schema.ts";

// Stable across requests so it can be prompt-cached.
export const SYSTEM_PROMPT = `You turn a traveller's pasted itinerary into a structured draft for a travel app.

The text may come from ChatGPT, a LINE chat, a notes app or anywhere else, and may mix Traditional Chinese, Korean, Japanese and English. The traveller reviews your draft on a confirmation screen before anything is saved, so your job is to capture what the text says and flag what is unclear, not to fill gaps.

What counts as a stop: a place the traveller plans to be at (restaurant, cafe, shop, sight, hotel), or a timed transport leg such as a flight, train or ferry. Budgets, packing reminders, tips, and chat that doesn't commit to a plan are not stops; mention anything important about them in warnings.

For each stop:
- source_excerpt: copy the exact span of the input it came from, unchanged.
- place_name: the name as written. Do not translate, correct or complete it; null if no place is named.
- branch_hint and search_query: include the area or branch only if the text gives one. For a chain or brand name without a branch or area (convenience stores, coffee chains, cosmetics chains, a shop the text names only by brand), add "ambiguous_branch": the app will ask which location.
- start_time/end_time: 24-hour HH:MM when stated. For vague times ("lunch", "afternoon", "around 3"), give your best reading, set time_is_approximate, and add "ambiguous_time". Leave null when nothing is said.
- fixed_suspected: true for flights, trains, ferries or buses with a set departure, reservations, bookings, and timed tickets. Say why in fixed_reason.
- needs_confirmation: "unknown_place" when it's unclear the name is a real, findable place; "ambiguous_date" when you can't tell which trip day it belongs to.

Days: map each stop to a date within the trip using the day labels in the text ("Day 2", "10/3", weekday names), in the traveller's local calendar. Keep day_label verbatim. If the day can't be determined or falls outside the trip dates, put the stops in a day with date null.

Never add addresses, opening hours, prices, or stock information, and never invent stops the text doesn't mention.`;

// Lists each trip date with its weekday so weekday labels ("週五") map reliably.
export function tripCalendar(start: string, end: string): string[] {
  const days: string[] = [];
  const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  for (let d = new Date(`${start}T00:00:00Z`); d <= new Date(`${end}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + 1)) {
    days.push(`${d.toISOString().slice(0, 10)} (${names[d.getUTCDay()]})`);
  }
  return days;
}

export function userMessage(input: ParseInput): string {
  return [
    `Trip dates: ${tripCalendar(input.tripStart, input.tripEnd).join(", ")}`,
    `Trip time zone: ${input.timeZone}`,
    "",
    "<itinerary>",
    input.rawText,
    "</itinerary>",
  ].join("\n");
}
