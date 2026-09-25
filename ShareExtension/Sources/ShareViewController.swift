import AppCore
import ShareCore
import SwiftUI
import UIKit

/// 分享到 BearTravel：最小閉環（WP6）。DEBUG build 可另開 Payload Inspector（S2）。
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareRootView(model: model, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
    }
}

@MainActor
@Observable
final class ShareModel {
    var record: PayloadRecord?
    let repository = BackendConfig.fromBundle().map { TripRepository(client: Backend.makeClient($0)) }
    let matcher = RouteMatcher(provider: AppleMapKitProvider())

    func start(_ items: [NSExtensionItem]) {
        Task { record = await PayloadInspector.inspect(items) }
    }
}

struct ShareRootView: View {
    let model: ShareModel
    let finish: () -> Void
    @State private var done: String?
    @State private var showsInspector = false

    var body: some View {
        NavigationStack {
            Group {
                if let done {
                    ContentUnavailableView(done, systemImage: "checkmark.circle")
                        .task { try? await Task.sleep(for: .seconds(1.2)); finish() }
                } else if let record = model.record {
                    let content = ShareContent(record: record)
                    ShareFlowView(content: content, repository: model.repository, matcher: model.matcher,
                                  placeSearch: MapKitPlaceSearch(),
                                  saveDraft: { try ShareDraftStore.shared()?.save(ShareDraft(content: content)) }) { outcome in
                        done = switch outcome {
                        case .added: "已加入行程"
                        case .saved(let duplicate): duplicate ? "已在收藏清單，已標記想去" : "已加入收藏"
                        case .draftSaved: "已存成草稿，開啟 App 後繼續"
                        }
                    }
                } else {
                    ProgressView("讀取分享內容…")
                }
            }
            .navigationTitle("BearTravel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: finish) }
                #if DEBUG
                ToolbarItem(placement: .primaryAction) {
                    Button("分享紀錄", systemImage: "ladybug") { showsInspector = true }.disabled(model.record == nil)
                }
                #endif
            }
            .sheet(isPresented: $showsInspector) {
                if let record = model.record { InspectorSheet(record: record) }
            }
        }
    }
}

/// S2 Payload Inspector：把這次分享的 payload 記錄到 App Group，供匯出整理矩陣。
struct InspectorSheet: View {
    @State var record: PayloadRecord
    @State private var sourceLabel = ""
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("來源標籤（整理矩陣用）") {
                    TextField("例如：Threads 單圖", text: $sourceLabel)
                }
                Section("內容（\(record.totalDurationMs) ms）") {
                    ForEach(Array(record.items.flatMap(\.attachments).flatMap(\.loads).enumerated()), id: \.offset) { _, load in
                        VStack(alignment: .leading) {
                            Text(load.typeIdentifier).font(.caption.monospaced().bold())
                            Text(load.preview ?? load.error ?? load.kind.rawValue).font(.caption).lineLimit(3)
                        }
                    }
                }
                if let status { Text(status) }
            }
            .navigationTitle("分享內容紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("記錄") {
                        record.sourceLabel = sourceLabel.isEmpty ? nil : sourceLabel
                        do {
                            guard let store = PayloadLogStore.shared() else { status = "App Group 未設定"; return }
                            try store.save(record)
                            status = "已記錄，可在 App 的「除錯 → 分享內容紀錄」匯出"
                        } catch {
                            status = "寫入失敗：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}
