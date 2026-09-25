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
  const record = (status: string, result: unknown, err: string | null, model: string | null) =>
    admin.rpc("record_parse_result", {
      p_import_id: importId,
      p_status: status,
      p_result: result,
      p_error: err,
      p_model: model,
    });

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    await record("failed", null, "missing_api_key", null);
    return json({ status: "failed", reason: "missing_api_key" });
  }

  await record("parsing", null, null, null);

  // Progress for the waiting screen: at most one write every 1.5 s, in order.
  let lastWrite = 0;
  let writing = Promise.resolve();
  const onProgress = (progress: unknown) => {
    const now = Date.now();
    if (now - lastWrite < 1500) return;
    lastWrite = now;
    writing = writing.then(async () => {
      await admin.rpc("record_parse_progress", { p_import_id: importId, p_progress: progress });
    }).catch(() => {});
  };

  try {
    const outcome = await parseItinerary(new Anthropic({ apiKey }), {
      tripStart: session.start_date,
      tripEnd: session.end_date,
      timeZone: session.time_zone,
      rawText: session.raw_text,
    }, { model: Deno.env.get("ANTHROPIC_MODEL") || undefined, onProgress });
    await writing;
    if (outcome.status === "failed") {
      await record("failed", null, outcome.reason, null);
      return json({ status: "failed", reason: outcome.reason });
    }
    await record("parsed", { draft: outcome.result, issues: outcome.issues }, null, outcome.model);
    return json({ status: "parsed" });
  } catch (e) {
    // Network or API errors: keep the raw text so the user can retry.
    console.error("parse-import failed", e instanceof Error ? e.message : e);
    await record("failed", null, "provider_error", null);
    return json({ status: "failed", reason: "provider_error" });
  }
});
