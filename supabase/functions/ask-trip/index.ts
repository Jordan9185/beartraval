// AI trip assistant (WP10). POST { trip_id, question, today?, route_facts? } with the user's JWT.
//
// Builds the trip context with the user's own permissions (RLS), so members
// only ever ask about trips they belong to. Route facts come from the app
// (computed on device with Apple Maps) and are checked against the trip.
// Nothing here writes the itinerary: a suggested change is returned as a
// proposal hint that the app turns into a change proposal the user confirms.
// Logs carry timings and token counts only, never the prompt (D11).

import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";
import { askTrip } from "../../../ai/trip-assistant/src/ask.ts";
import { TripContext } from "../../../ai/trip-assistant/src/schema.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "UNAUTHENTICATED" }, 401);

  let body: { trip_id?: string; question?: string; today?: string | null; route_facts?: unknown[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const question = (body.question ?? "").trim();
  if (!body.trip_id || question.length === 0 || question.length > 2000) return json({ error: "INVALID_REQUEST" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;
  const db = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    db: { schema: "app" },
  });
  const { data: userData } = await db.auth.getUser(auth.replace(/^Bearer /, ""));
  const userId = userData.user?.id;
  if (!userId) return json({ error: "UNAUTHENTICATED" }, 401);

  const { data: trip } = await db.from("trips").select("*").eq("id", body.trip_id).maybeSingle();
  if (!trip) return json({ error: "NOT_FOUND" }, 404);

  // Per-user limit on AI calls.
  const { data: allowed } = await db.rpc("consume_ai_quota", { p_kind: "ask" });
  if (allowed !== true) return json({ status: "failed", reason: "rate_limited" });

  // Every query is scoped to this trip: RLS alone would return rows from all the
  // caller's trips, cut off at PostgREST's max_rows. A failed query means the
  // context is incomplete, so nothing is answered from it.
  const [days, stops, saved, items, members] = await Promise.all([
    db.from("trip_days").select("*").eq("trip_id", trip.id).order("display_order"),
    db.from("stops").select("*").eq("trip_id", trip.id).is("deleted_at", null).order("sort_order"),
    db.from("saved_places").select("*").eq("trip_id", trip.id).neq("status", "dismissed"),
    db.from("shopping_items").select("*").eq("trip_id", trip.id).is("deleted_at", null),
    db.from("trip_members").select("user_id").eq("trip_id", trip.id).eq("status", "active"),
  ]);
  const savedIdList = (saved.data ?? []).map((s) => s.id);
  const itemIdList = (items.data ?? []).map((i) => i.id);
  const none = Promise.resolve({ data: [] as any[], error: null });
  const [interests, events, merchants] = await Promise.all([
    savedIdList.length ? db.from("saved_interests").select("saved_id, user_id").in("saved_id", savedIdList) : none,
    itemIdList.length ? db.from("purchase_events").select("item_id, type, id").in("item_id", itemIdList).order("id") : none,
    itemIdList.length
      ? db.from("merchant_candidates").select("item_id, place_id, evidence_type").in("item_id", itemIdList)
      : none,
  ]);
  const contextFailed = () => {
    console.log(JSON.stringify({ fn: "ask-trip", status: "failed", reason: "context_error" }));
    return json({ status: "failed", reason: "context_error" });
  };
  if ([days, stops, saved, items, members, interests, events, merchants].some((r) => r.error)) return contextFailed();

  const placeIds = new Set<string>([
    ...(stops.data ?? []).map((s) => s.place_id).filter(Boolean),
    ...(saved.data ?? []).map((s) => s.place_id).filter(Boolean),
    ...(merchants.data ?? []).map((m) => m.place_id),
  ]);
  const [placesResult, profilesResult] = await Promise.all([
    db.from("places").select("id, name, name_local").in("id", [...placeIds]),
    db.from("profiles").select("user_id, display_name").in("user_id", (members.data ?? []).map((m) => m.user_id)),
  ]);
  if (placesResult.error || profilesResult.error) return contextFailed();
  const places = placesResult.data;
  const profiles = profilesResult.data;
  const placeName = (id: string | null) => {
    const p = (places ?? []).find((x) => x.id === id);
    return p ? (p.name_local ?? p.name) : null;
  };
  const who = (id: string) => (profiles ?? []).find((p) => p.user_id === id)?.display_name ?? "旅伴";

  const stopById = new Map((stops.data ?? []).map((s) => [s.id, s]));
  const dayById = new Map((days.data ?? []).map((d) => [d.id, d]));
  const savedIds = new Set((saved.data ?? []).map((s) => s.id));
  const dayIds = new Set((days.data ?? []).map((d) => d.id));

  const candidate = {
    trip: { name: trip.name, start_date: trip.start_date, end_date: trip.end_date, time_zone: trip.time_zone },
    today: body.today ?? null,
    days: (days.data ?? []).map((d) => ({
      id: d.id,
      date: d.local_date,
      transport_mode: d.transport_mode,
      stops: (stops.data ?? []).filter((s) => s.day_id === d.id).map((s) => ({
        id: s.id,
        label: placeName(s.place_id) ?? s.raw_label,
        start_time: s.start_time ? String(s.start_time).slice(0, 5) : null,
        fixed: s.fixed,
        kind: s.kind,
        place_confirmed: s.place_id !== null,
      })),
    })),
    saved: (saved.data ?? []).map((s) => ({
      id: s.id,
      label: placeName(s.place_id) ?? s.raw_label,
      category: s.category,
      place_confirmed: s.place_id !== null,
      added_by: who(s.added_by),
      interested: (interests.data ?? []).filter((i) => i.saved_id === s.id).map((i) => who(i.user_id)),
    })),
    shopping: (items.data ?? []).map((i) => {
      const last = (events.data ?? []).filter((e) => e.item_id === i.id).at(-1);
      const stop = i.planned_stop_id ? stopById.get(i.planned_stop_id) : undefined;
      return {
        id: i.id,
        name: i.name,
        status: last?.type === "purchased" ? "purchased" : stop ? "scheduled" : "unscheduled",
        planned_date: stop ? (dayById.get(stop.day_id)?.local_date ?? null) : null,
        planned_store: stop ? placeName(stop.place_id) : null,
        merchants: (merchants.data ?? []).filter((m) => m.item_id === i.id)
          .map((m) => ({ name: placeName(m.place_id) ?? "?", evidence: m.evidence_type })),
      };
    }),
    // Only facts about this trip's saved places and days are accepted.
    route_facts: (Array.isArray(body.route_facts) ? body.route_facts : [])
      .filter((f: any) => f && savedIds.has(f.saved_id) && dayIds.has(f.day_id)).slice(0, 50),
  };
  const context = TripContext.safeParse(candidate);
  if (!context.success) return json({ error: "INVALID_CONTEXT", detail: context.error.message }, 422);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "app" } });
  const record = (status: string, answer: unknown, model: string | null) =>
    admin.from("ai_messages").insert({ trip_id: trip.id, user_id: userId, question, answer, status, model });

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    await record("failed", null, null);
    return json({ status: "failed", reason: "missing_api_key" });
  }

  const started = Date.now();
  try {
    const outcome = await askTrip(new Anthropic({ apiKey }), context.data, question,
      { model: Deno.env.get("ANTHROPIC_MODEL") || undefined });
    const latency_ms = Date.now() - started;
    if (outcome.status === "failed") {
      console.log(JSON.stringify({ fn: "ask-trip", status: "failed", reason: outcome.reason, latency_ms }));
      await record("failed", null, null);
      return json({ status: "failed", reason: outcome.reason });
    }
    console.log(JSON.stringify({ fn: "ask-trip", status: "answered", latency_ms, model: outcome.model, ...outcome.usage, issues: outcome.issues.length }));
    await record("answered", outcome.answer, outcome.model);
    return json({ status: "answered", answer: outcome.answer });
  } catch (e) {
    console.log(JSON.stringify({ fn: "ask-trip", status: "error", latency_ms: Date.now() - started, error: e instanceof Error ? e.name : "unknown" }));
    await record("failed", null, null);
    return json({ status: "failed", reason: "provider_error" });
  }
});
