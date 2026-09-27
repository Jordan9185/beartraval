import { enqueuePersonalAI } from "../_shared/personal-ai.ts";
// AI Gateway for text import (WP3): parses an import session's raw text with
// the S3 parser and stores the draft. The draft is never itinerary data; the
// user confirms every stop in the app before commit_import writes anything.
//
// POST { "import_id": uuid } with the user's JWT.
// Result is also written to app.import_sessions (parse_status / parse_result).

import { createClient } from "@supabase/supabase-js";

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

    if (session.parse_status === "parsed") return json({ status: "parsed" });
    return enqueuePersonalAI(auth, "parse", {
      tripName: session.trip_name, tripStart: session.start_date, tripEnd: session.end_date,
      timeZone: session.time_zone, rawText: session.raw_text,
    }, { import_id: importId });
});
