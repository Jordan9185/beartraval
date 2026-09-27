// App 查自己的工作；Mac 以專用憑證領取限定帳號的工作，不持有資料庫或 ChatGPT 雲端憑證。
import { activitySummary } from "../_shared/personal-ai-activity.ts";
import { adminClient, reply } from "../_shared/personal-ai.ts";

const UUID = /^[0-9a-f-]{36}$/i;
async function sameSecret(a: string, b: string): Promise<boolean> {
  if (!a || !b) return false;
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [x, y] = await Promise.all([digest(a), digest(b)]);
  let difference = 0;
  for (let i = 0; i < x.length; i++) difference |= x[i] ^ y[i];
  return difference === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > 1_000_000) return reply({ error: "TOO_LARGE" }, 413);
  let body;
  try { body = await req.json(); } catch { return reply({ error: "INVALID_REQUEST" }, 400); }
  const admin = adminClient();
  if (body.action === "status" || body.action === "activity") {
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!token) return reply({ error: "UNAUTHENTICATED" }, 401);
    const { data: auth } = await admin.auth.getUser(token);
    if (!auth.user) return reply({ error: "UNAUTHENTICATED" }, 401);
    if (body.action === "activity") {
      const columns = "id,kind,status,reason,created_at,updated_at,context,query:input->>query,trip_name:input->>tripName,model:result->>model";
      const [active, recent] = await Promise.all([
        admin.from("personal_ai_jobs").select(columns).eq("owner_id", auth.user.id)
          .in("status", ["queued", "running"]).order("created_at"),
        admin.from("personal_ai_jobs").select(columns).eq("owner_id", auth.user.id)
          .in("status", ["completed", "failed"]).order("updated_at", { ascending: false }).limit(10),
      ]);
      if (active.error || recent.error) return reply({ error: "READ_ERROR" }, 503);
      return reply({ jobs: activitySummary([...(active.data ?? []), ...(recent.data ?? [])]) });
    }
    if (!UUID.test(body.job_id ?? "")) return reply({ error: "INVALID_REQUEST" }, 400);
    const { data: job } = await admin.from("personal_ai_jobs").select("status,result,reason")
      .eq("id", body.job_id).eq("owner_id", auth.user.id).maybeSingle();
    if (!job) return reply({ error: "NOT_FOUND" }, 404);
    return reply(job.result ?? { status: job.status, job_id: body.job_id, reason: job.reason ?? (job.status === "running" ? "personal_ai_running" : "personal_ai_waiting") });
  }
  const owner = Deno.env.get("PERSONAL_AI_OWNER_ID");
  if (!owner || !await sameSecret(req.headers.get("X-Personal-AI-Token") ?? "",
    Deno.env.get("PERSONAL_AI_WORKER_TOKEN") ?? "")) return reply({ error: "UNAUTHENTICATED" }, 401);

  if (body.action === "claim") {
    const { data, error } = await admin.rpc("claim_personal_ai", { p_owner: owner });
    if (error) return reply({ error: "QUEUE_ERROR" }, 503);
    return reply({ job: data?.id ? data : null });
  }
  if (!UUID.test(body.job_id ?? "") || !UUID.test(body.lease ?? "")) return reply({ error: "INVALID_REQUEST" }, 400);
  if (body.action === "complete") {
    if (!body.result || !["parsed", "answered", "extracted", "ready", "found", "none", "failed"].includes(body.result.status)
      || JSON.stringify(body.result).length > 500_000 || !/^codex\/gpt-[a-z0-9.-]+$/.test(body.model ?? "")) {
      return reply({ error: "INVALID_RESULT" }, 422);
    }
    const { data, error } = await admin.rpc("finish_personal_ai", {
      p_owner: owner, p_id: body.job_id, p_lease: body.lease, p_result: body.result, p_model: body.model,
    });
    if (error) { console.error("personal-ai finish", { code: error.code }); return reply({ error: "SAVE_ERROR" }, 503); }
    const { data: latest } = await admin.from("personal_ai_jobs").select("status").eq("id", body.job_id).eq("owner_id", owner).maybeSingle();
    return reply({ accepted: data === true, terminal: !latest || ["completed", "failed"].includes(latest.status) });
  }
  if (body.action === "heartbeat" || body.action === "defer") {
    const deferred = body.action === "defer";
    const reason = ["personal_ai_limit", "personal_ai_login", "personal_ai_waiting"].includes(body.reason)
      ? body.reason : "personal_ai_waiting";
    const now = new Date();
    const change = deferred
      ? { status: "queued", lease: null, lease_until: null, reason,
        available_at: new Date(now.getTime() + 15 * 60_000).toISOString(), updated_at: now.toISOString() }
      : { lease_until: new Date(now.getTime() + 3 * 60_000).toISOString(), updated_at: now.toISOString() };
    const { data, error } = await admin.from("personal_ai_jobs").update(change).eq("id", body.job_id)
      .eq("owner_id", owner).eq("lease", body.lease).eq("status", "running").gt("lease_until", now.toISOString())
      .select("kind,context").maybeSingle();
    if (error) return reply({ error: "QUEUE_ERROR" }, 503);
    if (data?.kind === "parse" && deferred) await admin.rpc("record_parse_progress", {
      p_import_id: data.context.import_id, p_attempt: data.context.attempt,
      p_progress: { stage: reason, days: 0, stops: 0, last_place: null },
    });
    return reply({ accepted: !!data });
  }
  return reply({ error: "INVALID_REQUEST" }, 400);
});
