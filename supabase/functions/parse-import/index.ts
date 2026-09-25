// AI Gateway for text import (WP3): parses an import session's raw text with
// the S3 parser and stores the draft. The draft is never itinerary data; the
// user confirms every stop in the app before commit_import writes anything.
//
// POST { "import_id": uuid } with the user's JWT.
// Result is also written to app.import_sessions (parse_status / parse_result).

import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";
import { parseItinerary } from "../../../ai/itinerary-parse/src/parse.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "UNAUTHENTICATED" }, 401);

  let importId: string | undefined;
  try {
    importId = (await req.json())?.import_id;
  } catch {
    // fall through
  }
  if (!importId) return json({ error: "INVALID_REQUEST" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;
  // RLS decides whether this user may see the import.
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    db: { schema: "app" },
  });
  const { data: session, error } = await asUser.from("import_sessions").select("*").eq("id", importId).maybeSingle();
  if (error) return json({ error: "UNAUTHENTICATED" }, 401);
  if (!session) return json({ error: "NOT_FOUND" }, 404);
  if (session.trip_id) return json({ error: "ALREADY_COMMITTED" }, 409);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "app" } });

  // Only one parse per import at a time; a retry while one is running just waits for it
  // (and uses no quota). The attempt id ties every write below to this parse: if the user
  // edits the text meanwhile, update_import_text ends the attempt and our result is dropped.
  const { data: attempt } = await admin.rpc("begin_parse", { p_import_id: importId });
  if (!attempt) return json({ status: "parsing" }, 409);

  const record = async (status: string, result: unknown, err: string | null, model: string | null) => {
    const { data } = await admin.rpc("record_parse_result", {
      p_import_id: importId,
      p_attempt: attempt,
      p_status: status,
      p_result: result,
      p_error: err,
      p_model: model,
    });
    return data === true;
  };

  // Read the text again after claiming: an edit made before the claim is what we parse;
  // one made after it ends this attempt.
  const { data: claimed } = await asUser.from("import_sessions")
    .select("start_date, end_date, time_zone, raw_text, parse_attempt").eq("id", importId).maybeSingle();
  if (!claimed) {
    await record("failed", null, "provider_error", null);
    return json({ status: "failed", reason: "provider_error" });
  }
  if (claimed.parse_attempt !== attempt) return json({ status: "superseded" }, 409);

  // One JSON line per parse: timings, token counts and status only, never the text (D11).
  const started = Date.now();
  const log = (fields: Record<string, unknown>) =>
    console.log(JSON.stringify({ fn: "parse-import", ms: Date.now() - started, input_tokens: null, output_tokens: null, ...fields }));

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    await record("failed", null, "missing_api_key", null);
    log({ status: "failed", reason: "missing_api_key" });
    return json({ status: "failed", reason: "missing_api_key" });
  }

  // Per-user limit on AI calls (each parse costs money).
  const { data: allowed } = await asUser.rpc("consume_ai_quota", { p_kind: "parse" });
  if (allowed !== true) {
    await record("failed", null, "rate_limited", null);
    log({ status: "failed", reason: "rate_limited" });
    return json({ status: "failed", reason: "rate_limited" }, 429);
  }

  // Progress for the waiting screen: at most one write every 1.5 s, in order.
  let lastWrite = 0;
  let writing = Promise.resolve();
  const onProgress = (progress: unknown) => {
    const now = Date.now();
    if (now - lastWrite < 1500) return;
    lastWrite = now;
    writing = writing.then(async () => {
      await admin.rpc("record_parse_progress", { p_import_id: importId, p_attempt: attempt, p_progress: progress });
    }).catch(() => {});
  };

  try {
    const outcome = await parseItinerary(new Anthropic({ apiKey }), {
      tripStart: claimed.start_date,
      tripEnd: claimed.end_date,
      timeZone: claimed.time_zone,
      rawText: claimed.raw_text,
    }, { model: Deno.env.get("ANTHROPIC_MODEL") || undefined, onProgress });
    await writing;
    if (outcome.status === "failed") {
      const recorded = await record("failed", null, outcome.reason, null);
      log({ status: recorded ? "failed" : "superseded", reason: outcome.reason });
      return json({ status: recorded ? "failed" : "superseded", reason: outcome.reason });
    }
    const recorded = await record("parsed", { draft: outcome.result, issues: outcome.issues }, null, outcome.model);
    log({ status: recorded ? "parsed" : "superseded", model: outcome.model, ...outcome.usage, issues: outcome.issues.length });
    return json({ status: recorded ? "parsed" : "superseded" });
  } catch (e) {
    // Network or API errors: keep the raw text so the user can retry.
    log({ status: "error", error: e instanceof Error ? e.name : "unknown" });
    await record("failed", null, "provider_error", null);
    return json({ status: "failed", reason: "provider_error" });
  }
});
