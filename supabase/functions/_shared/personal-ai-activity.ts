// 僅回傳畫面需要的進度，不將原圖、原文、租約或工作憑證送到 App。
export function activitySummary(rows: Array<Record<string, any>>) {
  const queued = rows.filter((row) => row.status === "queued")
    .sort((a, b) => a.created_at.localeCompare(b.created_at));
  return rows.map((row) => ({
    id: row.id, kind: row.kind, status: row.status, reason: row.reason,
    label: String(row.context?.display_label || row.query || row.trip_name || "").slice(0, 80),
    created_at: row.created_at, updated_at: row.updated_at,
    queue_position: row.status === "queued" ? queued.findIndex((item) => item.id === row.id) + 1 : null,
    model: row.model ?? null,
  }));
}
