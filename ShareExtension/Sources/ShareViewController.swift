import AppCore
import ShareCore
import SwiftUI
import UIKit

/// 分享到 BeaRTravel：先完整收件，之後在主 App 自動整理。
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
    var capture: InboxCapture?
    var cloudSynced = false
    var errorMessage: String?
    let repository = BackendConfig.fromBundle().map { InboxRepository(client: Backend.makeClient($0)) }
    private var inputItems: [NSExtensionItem] = []

    func start(_ items: [NSExtensionItem]) {
        inputItems = items
        Task {
            errorMessage = nil
            cloudSynced = false
            do {
                guard let store = InboxCaptureStore.shared() else { throw InboxCaptureError.appGroupUnavailable }
                var owner = repository?.currentUserID
                if owner == nil, let repository, let session = try? await repository.client.auth.session {
                    owner = session.user.id
                }
                let saved = try await store.capture(items, ownerHint: owner)
                capture = saved
                // 純文字／連結可直接送入雲端背景工作。多媒體先保留本機，避免分享面板等待大檔上傳。
                if let repository, saved.ownerHint != nil,
                   !saved.assets.contains(where: \.isVideo), saved.assets.count <= 3 {
                    let upload = Task { try await repository.sync(saved, from: store) }
                    let deadline = Task {
                        try? await Task.sleep(for: .seconds(6))
                        upload.cancel()
                    }
                    cloudSynced = (try? await upload.value) != nil
                    deadline.cancel()
                }
            } catch {
                errorMessage = "無法保存這次分享：\(error.localizedDescription)"
            }
        }
    }

    func inspect() {
        Task { record = await PayloadInspector.inspect(inputItems, timeout: 5) }
    }

    func retry() { start(inputItems) }
}

struct ShareRootView: View {
    let model: ShareModel
    let finish: () -> Void
    @State private var showsInspector = false

    var body: some View {
        NavigationStack {
            Group {
                if let capture = model.capture {
                    ContentUnavailableView {
                        Label(model.cloudSynced ? "已同步，正在整理" : "已保存在此裝置", systemImage: "checkmark.circle")
                    } description: {
                        Text(capture.ownerHint == nil
                             ? "下次登入 App 時確認歸屬，即可自動整理。"
                             : model.cloudSynced ? "已同步，正在自動整理。" : "開啟 BeaRTravel 後會同步並整理，不需要先選旅程或類別。")
                    }
                    .task { try? await Task.sleep(for: .seconds(1.2)); finish() }
                } else if let errorMessage = model.errorMessage {
                    ContentUnavailableView {
                        Label("分享未保存", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重試") { model.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("保存分享內容…")
                }
            }
            .navigationTitle("BeaRTravel")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.bearBrown)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: finish) }
                #if DEBUG
                ToolbarItem(placement: .primaryAction) {
                    Button("分享紀錄", systemImage: "ladybug") { model.inspect(); showsInspector = true }
                }
                #endif
            }
            .sheet(isPresented: $showsInspector) {
                if let record = model.record { InspectorSheet(record: record) }
                else { ProgressView("讀取分享紀錄…") }
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
