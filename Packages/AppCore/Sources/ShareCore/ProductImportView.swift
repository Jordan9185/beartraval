import AppCore
import PhotosUI
import SwiftUI

/// 從貼文、截圖或文字加入購物清單（規格 §3.6）：AI 辨識出商品草稿，
/// 使用者勾選、修改後才加入。Extension 與 App 共用。
/// 只記「想買什麼」，不代表哪裡有賣或有庫存（規則 6）。
public struct ProductImportView: View {
    let repository: TripRepository?
    let discoveryRepository: InboxRepository?
    let sourceURL: URL?
    let preferredTripID: UUID?
    let onFinish: (Int) -> Void

    @State private var text: String
    @State private var imageJPEG: Data?
    @State private var photo: PhotosPickerItem?
    @State private var trips: [Trip] = []
    @State private var tripsLoaded = false
    @State private var tripID: UUID?
    @State private var drafts: [Draft] = []
    @State private var warnings: [String] = []
    @State private var extracting = false
    @State private var extracted = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var editingDraftIDs: Set<UUID> = []
    @State private var saveOperationIDs: [UUID: [UUID: UUID]] = [:]
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case text
        case draft(UUID)
    }

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var note: String?
        var selected: Bool
        var confidence: String
        var storeHint: String?
        var storeEvidence: String?
        /// 使用辨識當下的名稱查店，避免使用者修改欄位時連續重送 AI 請求。
        var lookupName: String? = nil
        /// 使用者自己加的項目；重新辨識時保留。
        var manual = false
    }

    public init(content: ShareContent, repository: TripRepository?, discoveryRepository: InboxRepository? = nil,
                preferredTripID: UUID? = nil,
                onFinish: @escaping (Int) -> Void) {
        self.repository = repository
        self.discoveryRepository = discoveryRepository
        self.sourceURL = content.urls.first
        self.preferredTripID = preferredTripID
        self.onFinish = onFinish
        _text = State(initialValue: ([content.title] + content.texts).compactMap { $0 }.joined(separator: "\n"))
        _imageJPEG = State(initialValue: content.imageJPEG)
    }

    private var hasInput: Bool { imageJPEG != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedCount: Int { drafts.filter(\.selected).count }
    private var selectedTrip: Trip? { trips.first { $0.id == tripID } }

    public var body: some View {
        Form {
            Section {
                if let imageJPEG, let image = platformImage(imageJPEG) {
                    image.resizable().scaledToFit().frame(maxHeight: extracted ? 120 : 220).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if extracted {
                    Text("已辨識 \(drafts.filter { !$0.manual }.count) 項商品，勾選想買的即可加入。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("更換照片或修改貼文文字") { sourceEditor }
                } else {
                    sourceEditor
                }
            } header: {
                Text("分享內容")
            }

            Section {
                if extracting { ProgressView("AI 正在辨識商品…") }
                if !extracting && extracted && drafts.isEmpty {
                    Text("沒有辨識到商品，可以手動新增。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !extracting { ForEach($drafts) { $draft in
                    HStack(alignment: .firstTextBaseline) {
                        Button { draft.selected.toggle() } label: {
                            Image(systemName: draft.selected ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            if editingDraftIDs.contains(draft.id) {
                                TextField("商品名稱", text: $draft.name)
                                    .focused($focus, equals: .draft(draft.id))
                            } else {
                                Text(draft.name.isEmpty ? "未命名商品" : draft.name)
                                    .font(.subheadline.weight(.semibold))
                            }
                            if draft.confidence == "low" {
                                Text("AI 不太確定，請核對名稱").font(.caption).foregroundStyle(.orange)
                            }
                            if let storeHint = draft.storeHint {
                                Text("貼文提到：\(storeHint) · 販售與庫存待確認")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            if editingDraftIDs.contains(draft.id) {
                                editingDraftIDs.remove(draft.id)
                                draft.lookupName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                focus = nil
                            } else {
                                editingDraftIDs.insert(draft.id)
                                focus = .draft(draft.id)
                            }
                        } label: {
                            Image(systemName: editingDraftIDs.contains(draft.id) ? "checkmark" : "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(editingDraftIDs.contains(draft.id) ? "完成修改商品名稱" : "修改商品名稱")
                    }
                    if let discoveryRepository, let lookupName = draft.lookupName,
                       draft.selected, let selectedTrip,
                       drafts.prefix(3).contains(where: { $0.id == draft.id }) {
                        ProductStoreSuggestionsView(repository: discoveryRepository, productName: lookupName,
                                                    storeHint: draft.storeHint, region: selectedTrip.name,
                                                    countryCode: LocalMapCountry.guess(name: selectedTrip.name,
                                                                                       timeZone: selectedTrip.timeZone))
                    }
                } }
                Button("手動新增一項", systemImage: "plus") {
                    let draft = Draft(name: "", note: nil, selected: true, confidence: "high", storeHint: nil, storeEvidence: nil, manual: true)
                    drafts.append(draft)
                    editingDraftIDs.insert(draft.id)
                    focus = .draft(draft.id)
                }
                if !warnings.isEmpty {
                    DisclosureGroup("辨識提醒（\(warnings.count)）") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Text(verbatim: warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("商品")
            } footer: {
                Text("只加入你勾選的項目；是否有賣、有沒有庫存要另外確認。")
            }

            if trips.count > 1 && !trips.contains(where: { $0.id == preferredTripID }) {
                Picker("旅程", selection: $tripID) {
                    ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                }
            } else if trips.isEmpty && tripsLoaded {
                Text("沒有可以新增的旅程。請先建立旅程，或請擁有者給你編輯權限。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(saving ? "加入中…" : "加入購物清單（\(selectedCount)）") { Task { await save() } }
                    .disabled(saving || tripID == nil || !drafts.contains { $0.selected && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
                    .accessibilityIdentifier("addProducts")
                if let errorMessage { ErrorText(errorMessage) }
            }
        }
        // 多行輸入框按 return 是換行，所以另外提供收鍵盤的方式。
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focus = nil }
            }
        }
        .task {
            guard let repository else { return }
            trips = (try? await repository.editableTrips()) ?? []
            tripsLoaded = true
            if tripID == nil {
                tripID = trips.first { $0.id == preferredTripID }?.id ?? ShareFlowView.defaultTrip(trips)?.id
            }
            // 分享進來就帶著截圖或貼文時，直接辨識，不必再按一次。
            if hasInput && !extracted { await extract() }
        }
        .onChange(of: photo) {
            Task {
                guard let data = try? await photo?.loadTransferable(type: Data.self) else { return }
                imageJPEG = ImageDownscale.jpeg(from: data, maxPixel: 2048)
                // 選了新照片就自動辨識。
                await extract()
            }
        }
    }

    private var sourceEditor: some View {
        let photoLabel = imageJPEG == nil ? "選擇截圖或照片" : "換一張"
        return VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $photo, matching: .images) {
                Label(photoLabel, systemImage: "photo")
            }
            TextField("貼文文字、商品名稱或連結", text: $text, axis: .vertical).lineLimit(3...8)
                .focused($focus, equals: .text)
                .accessibilityIdentifier("productText")
            if let sourceURL { Text(sourceURL.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Button(extracting ? "辨識中…" : extracted ? "重新辨識" : "用 AI 辨識商品", systemImage: "sparkles") {
                Task { await extract() }
            }
            .disabled(!hasInput || extracting || repository == nil || tripID == nil)
        }
    }

    private func extract() async {
        guard let repository, let tripID, !extracting, hasInput else { return }
        focus = nil
        extracting = true
        defer { extracting = false }
        drafts.removeAll { !$0.manual }
        warnings = []
        extracted = false
        errorMessage = nil
        do {
            let result = try await repository.extractProducts(tripID: tripID, text: text, url: sourceURL?.absoluteString, imageJPEG: imageJPEG)
            // 重新辨識時換掉上次 AI 的結果，保留自己加的項目。
            drafts = result.products.map {
                Draft(name: $0.listName, note: $0.searchQuery, selected: $0.confidence != "low",
                      confidence: $0.confidence, storeHint: $0.storeHint, storeEvidence: $0.storeEvidence,
                      lookupName: $0.listName)
            } + drafts.filter { $0.manual && !$0.name.isEmpty }
            editingDraftIDs = Set(drafts.filter { $0.confidence == "low" || $0.manual }.map(\.id))
            warnings = result.warnings
            extracted = true
            errorMessage = nil
        } catch let error as ProductExtractionError {
            errorMessage = error.userMessage
        } catch let error as BackendError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "辨識失敗：\(userMessage(for: error))"
        }
    }

    private func save() async {
        guard let repository, let tripID else { return }
        saving = true
        defer { saving = false }
        var added = 0
        do {
            for draft in drafts where draft.selected {
                let name = draft.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let operationID = saveOperationIDs[tripID]?[draft.id] ?? UUID()
                saveOperationIDs[tripID, default: [:]][draft.id] = operationID
                let item = try await repository.addShoppingItem(tripID: tripID, name: String(name.prefix(200)), note: nil,
                                                                url: sourceURL?.absoluteString, clientOpID: operationID)
                added += 1
                if let storeHint = draft.storeHint {
                    try await repository.setShoppingStoreHint(itemID: item.id, name: storeHint, evidence: draft.storeEvidence)
                }
                if let discoveryRepository, let selectedTrip, name.count >= 2 {
                    let country = LocalMapCountry.guess(name: selectedTrip.name, timeZone: selectedTrip.timeZone)
                    let region = [country, selectedTrip.name].compactMap { $0 }.joined(separator: " ")
                    let found = try await discoveryRepository.discoverStores(
                        product: name, storeHint: draft.storeHint, region: region)
                    try await repository.setShoppingStoreSuggestions(itemID: item.id,
                        suggestions: found.map(ShoppingStoreSuggestion.init(discovered:)))
                }
                if let imageJPEG { try await repository.setShoppingImage(tripID: tripID, itemID: item.id, jpeg: imageJPEG) }
            }
            onFinish(added)
        } catch let error as BackendError {
            errorMessage = added > 0 ? "已加入 \(added) 項，其餘失敗：\(error.userMessage)" : error.userMessage
        } catch {
            errorMessage = "加入失敗：\(userMessage(for: error))"
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}
