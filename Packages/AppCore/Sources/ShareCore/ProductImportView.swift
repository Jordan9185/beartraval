import AppCore
import PhotosUI
import SwiftUI

/// 從貼文、截圖或文字加入購物清單（規格 §3.6）：AI 辨識出商品草稿，
/// 使用者勾選、修改後才加入。Extension 與 App 共用。
/// 只記「想買什麼」，不代表哪裡有賣或有庫存（規則 6）。
public struct ProductImportView: View {
    let repository: TripRepository?
    let sourceURL: URL?
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
        /// 使用者自己加的項目；重新辨識時保留。
        var manual = false
    }

    public init(content: ShareContent, repository: TripRepository?, onFinish: @escaping (Int) -> Void) {
        self.repository = repository
        self.sourceURL = content.urls.first
        self.onFinish = onFinish
        _text = State(initialValue: ([content.title] + content.texts).compactMap { $0 }.joined(separator: "\n"))
        _imageJPEG = State(initialValue: content.imageJPEG)
    }

    private var hasInput: Bool { imageJPEG != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedCount: Int { drafts.filter(\.selected).count }

    public var body: some View {
        Form {
            Section {
                if let imageJPEG, let image = platformImage(imageJPEG) {
                    image.resizable().scaledToFit().frame(maxHeight: 220).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(imageJPEG == nil ? "選擇截圖或照片" : "換一張", systemImage: "photo")
                }
                TextField("貼文文字、商品名稱或連結", text: $text, axis: .vertical).lineLimit(3...8)
                    .focused($focus, equals: .text)
                    .accessibilityIdentifier("productText")
                if let sourceURL { Text(sourceURL.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } header: {
                Text("貼文")
            } footer: {
                Text("IG／Threads 分享常常只給連結；拿不到圖時，可以先截圖再從這裡選。")
            }

            Section {
                Button(extracting ? "辨識中…" : extracted ? "重新辨識" : "用 AI 辨識商品", systemImage: "sparkles") { Task { await extract() } }
                    .disabled(!hasInput || extracting || repository == nil || tripID == nil)
                if extracting { ProgressView() }
                if extracted && drafts.isEmpty {
                    Text("沒有辨識到商品，可以直接在下方輸入名稱。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach($drafts) { $draft in
                    HStack(alignment: .firstTextBaseline) {
                        Button { draft.selected.toggle() } label: {
                            Image(systemName: draft.selected ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("商品名稱", text: $draft.name)
                                .focused($focus, equals: .draft(draft.id))
                            if draft.confidence == "low" {
                                Text("AI 不太確定，請核對名稱").font(.caption).foregroundStyle(.orange)
                            }
                            if let storeHint = draft.storeHint {
                                Text("貼文提到：\(storeHint) · 販售與庫存待確認")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("手動新增一項", systemImage: "plus") {
                    let draft = Draft(name: "", note: nil, selected: true, confidence: "high", storeHint: nil, storeEvidence: nil, manual: true)
                    drafts.append(draft)
                    focus = .draft(draft.id)
                }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Text(verbatim: warning).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("商品")
            } footer: {
                Text("只加入你勾選的項目；是否有賣、有沒有庫存要另外確認。")
            }

            if trips.count > 1 {
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
            if tripID == nil { tripID = ShareFlowView.defaultTrip(trips)?.id }
            // 分享進來就帶著截圖或貼文時，直接辨識，不必再按一次。
            if hasInput && !extracted { await extract() }
        }
        .onChange(of: photo) {
            Task {
                guard let data = try? await photo?.loadTransferable(type: Data.self) else { return }
                imageJPEG = ImageDownscale.jpeg(from: data)
                // 選了新照片就自動辨識。
                await extract()
            }
        }
    }

    private func extract() async {
        guard let repository, let tripID, !extracting, hasInput else { return }
        focus = nil
        extracting = true
        defer { extracting = false }
        do {
            let result = try await repository.extractProducts(tripID: tripID, text: text, url: sourceURL?.absoluteString, imageJPEG: imageJPEG)
            // 重新辨識時換掉上次 AI 的結果，保留自己加的項目。
            drafts = result.products.map {
                Draft(name: $0.listName, note: $0.searchQuery, selected: $0.confidence != "low",
                      confidence: $0.confidence, storeHint: $0.storeHint, storeEvidence: $0.storeEvidence)
            } + drafts.filter { $0.manual && !$0.name.isEmpty }
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
                let item = try await repository.addShoppingItem(tripID: tripID, name: String(name.prefix(200)), note: nil,
                                                                url: sourceURL?.absoluteString, clientOpID: UUID())
                if let storeHint = draft.storeHint {
                    try await repository.setShoppingStoreHint(itemID: item.id, name: storeHint, evidence: draft.storeEvidence)
                }
                if let imageJPEG { try await repository.setShoppingImage(tripID: tripID, itemID: item.id, jpeg: imageJPEG) }
                added += 1
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
