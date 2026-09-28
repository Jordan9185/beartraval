import AppCore
import Foundation

/// 匯入確認頁的逐站 AI 查找。已有工作 ID 時只查該筆狀態，不因重新開啟或切換 AI 模式另開新工作；
/// 結果只寫入仍屬於同一要求的草稿項目，不改使用者的選擇，也不動正式行程。
@MainActor
public struct ImportResearch {
    public let discovery: any PlaceDiscovering
    public let city: String?
    public let read: @MainActor (Int) -> ConfirmItem?
    public let write: @MainActor (Int, (inout ConfirmItem) -> Void) -> Void
    public var pollInterval: Duration = .seconds(3)
    /// 同時查找的上限；雲端另有每人工作數與額度限制，不為加速無限制並行。
    public static let maxConcurrent = 3

    public init(discovery: any PlaceDiscovering, city: String?, read: @escaping @MainActor (Int) -> ConfirmItem?,
                write: @escaping @MainActor (Int, (inout ConfirmItem) -> Void) -> Void) {
        self.discovery = discovery; self.city = city; self.read = read; self.write = write
    }

    /// 先接續已排入的工作，再依序開新工作；一站失敗不影響其他站。
    public func runAll(_ indices: [Int]) async {
        let ordered = indices.sorted { (read($0)?.researchJobID == nil ? 1 : 0) < (read($1)?.researchJobID == nil ? 1 : 0) }
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for index in ordered {
                if Task.isCancelled { break }
                if active >= Self.maxConcurrent { await group.next(); active -= 1 }
                group.addTask { await self.run(index) }
                active += 1
            }
        }
    }

    public func run(_ index: Int) async {
        guard let item = read(index) else { return }
        let request = item.researchRequest ?? UUID()
        write(index) { $0.researchRequest = request }
        func owns() -> Bool {
            guard let current = read(index) else { return false }
            return current.stop == item.stop && current.researchRequest == request
        }
        do {
            var progress: PlaceDiscoveryProgress
            if let job = item.researchJobID {
                progress = try await discovery.placeDiscoveryStatus(jobID: job)
            } else {
                let context = [item.stop.city ?? city, item.stop.sourceExcerpt, item.stop.searchQuery]
                    .compactMap { $0 }.joined(separator: "\n")
                progress = try await discovery.startPlaceDiscovery(query: item.label, context: context)
            }
            while case .pending(let job) = progress {
                guard owns() else { return }
                write(index) { $0.researchJobID = job }
                try await Task.sleep(for: pollInterval)
                guard owns() else { return }
                progress = try await discovery.placeDiscoveryStatus(jobID: job)
            }
            guard owns(), case .finished(let candidates) = progress else { return }
            write(index) {
                $0.researchCandidates = candidates.map(ShoppingStoreSuggestion.init(discovered:))
                $0.researchMessage = candidates.isEmpty ? "目前找不到可核對來源的店家，這項仍只保留名稱。" : nil
                $0.researchJobID = nil
                $0.searched = true
            }
        } catch {
            // 離開畫面時保留工作 ID，重新開啟接續同一筆。
            guard !Task.isCancelled, !(error is CancellationError), owns() else { return }
            if (error as? BackendError)?.isTransient == true || error is URLError {
                write(index) { $0.researchMessage = "暫時無法連線，查找工作已保留；恢復連線後重新開啟會接續。" }
                return
            }
            let message = (error as? PlaceDiscoveryError)?.userMessage ?? "店家查找失敗：\(userMessage(for: error))"
            write(index) {
                $0.researchJobID = nil
                $0.searched = true
                $0.researchMessage = message
            }
        }
    }
}
