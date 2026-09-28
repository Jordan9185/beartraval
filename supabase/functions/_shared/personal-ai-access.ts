const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 新名單存在時完全取代舊單一帳號設定；空白或錯誤設定不得意外放行。
export function personalAIUsers(configured: string | undefined, legacyOwner?: string): string[] {
  const value = configured ?? legacyOwner ?? "";
  if (!value.trim()) return [];
  const users = value.split(",").map((id) => id.trim().toLowerCase());
  if (users.some((id) => !UUID.test(id))) return [];
  return [...new Set(users)];
}

// 候選已依建立時間排序。先服務等待最久的帳號，再清理沒有候選的帳號。
export function personalAIClaimOrder(allowed: string[], candidates: { owner_id: string }[]): string[] {
  return [...new Set([...candidates.map((job) => job.owner_id).filter((id) => allowed.includes(id)), ...allowed])];
}
