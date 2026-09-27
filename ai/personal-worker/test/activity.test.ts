import assert from "node:assert/strict";
import test from "node:test";
import { activitySummary } from "../../../supabase/functions/_shared/personal-ai-activity.ts";

test("進度依真正佇列排序，不外洩原圖、原文或租約", () => {
  const base = { kind: "discover", reason: null, updated_at: "2026-09-27T00:01:00Z", input: { image: "private" }, lease: "secret" };
  const rows = [
    { ...base, id: "new", status: "queued", created_at: "2026-09-27T00:02:00Z", query: "新店家" },
    { ...base, id: "running", status: "running", created_at: "2026-09-27T00:00:00Z", context: { display_label: "處理中" } },
    { ...base, id: "old", status: "queued", created_at: "2026-09-27T00:01:00Z", query: "舊店家" },
    { ...base, id: "done", status: "completed", created_at: "2026-09-27T00:00:00Z", context: { display_label: "已完成的店家", attempt: "private" } },
  ];
  const result = activitySummary(rows);
  assert.deepEqual(result.map((job) => job.queue_position), [2, null, 1, null]);
  assert.equal(result[3].label, "已完成的店家");
  assert.ok(!JSON.stringify(result).includes("private"));
  assert.ok(!JSON.stringify(result).includes("secret"));
});
