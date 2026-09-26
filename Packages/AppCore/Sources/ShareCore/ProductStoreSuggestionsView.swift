import AppCore
import SwiftUI

/// 商品照片或貼文辨識後的店家線索；網頁只提供候選，行程定位與販售仍要確認。
public struct ProductStoreSuggestionsView: View {
    let repository: InboxRepository
    let productName: String
    let storeHint: String?
    let region: String
    let countryCode: String?
    let onSelect: ((DiscoveredPlace) -> Void)?

    @State private var candidates: [DiscoveredPlace] = []
    @State private var loading = false
    @State private var finished = false
    @State private var errorMessage: String?

    public init(repository: InboxRepository, productName: String, storeHint: String? = nil,
                region: String, countryCode: String?, onSelect: ((DiscoveredPlace) -> Void)? = nil) {
        self.repository = repository
        self.productName = productName
        self.storeHint = storeHint
        self.region = region
        self.countryCode = countryCode
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView("AI 正在查可能的實體店…") }
            if let errorMessage {
                ErrorText(errorMessage)
                Button("重新查店家") { Task { await search() } }
            } else if finished && candidates.isEmpty {
                Text("目前查不到可核對的實體店；商品已辨識，店家仍可稍後再查。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新查店家") { Task { await search() } }
            }
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.koreanName ?? candidate.name).font(.headline)
                    if let address = candidate.addressLocal {
                        Text(address).font(.subheadline).textSelection(.enabled)
                    }
                    Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                    Text("是否販售及庫存皆待確認").font(.caption).foregroundStyle(.secondary)
                    LocalMapSearchButtons(name: candidate.searchQuery, countryCode: countryCode)
                        .buttonStyle(.borderless)
                    if let url = URL(string: candidate.sourceURL), url.scheme == "https" {
                        Link("查看店家來源", destination: url).font(.caption)
                    }
                    if let onSelect {
                        Button("用這間店查行程定位") { onSelect(candidate) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task(id: "\(productName)|\(storeHint ?? "")|\(region)") { await search() }
    }

    private func search() async {
        let product = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard product.count >= 2, !loading else { return }
        loading = true
        finished = false
        errorMessage = nil
        candidates = []
        defer { loading = false; finished = true }
        do {
            let location = [countryCode, region].compactMap { $0 }.joined(separator: " ")
            candidates = try await repository.discoverStores(product: product, storeHint: storeHint, region: location)
        } catch let error as PlaceDiscoveryError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "店家查找失敗：\(userMessage(for: error))"
        }
    }
}
