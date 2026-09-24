import ShareCore
import SwiftUI
import UIKit

/// S2 Payload Inspector（issue #2）：記錄分享 payload 寫入 App Group，不做辨識。
///
/// WP6 會改成正式的最小確認卡；屆時此 inspector 只留在 Debug 設定。
final class ShareViewController: UIViewController {
    private let model = InspectorModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: InspectorSheet(model: model, onDone: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        model.start(items)
    }
}

@MainActor
@Observable
final class InspectorModel {
    enum State {
        case loading
        case captured(PayloadRecord)
        case saved(PayloadRecord)
        case failed(String)
    }

    var state: State = .loading
    var sourceLabel = ""

    func start(_ items: [NSExtensionItem]) {
        Task {
            state = .captured(await PayloadInspector.inspect(items))
        }
    }

    func save() {
        guard case .captured(var record) = state else { return }
        record.sourceLabel = sourceLabel.isEmpty ? nil : sourceLabel
        guard let store = PayloadLogStore.shared() else {
            state = .failed("App Group 未設定，無法寫入。")
            return
        }
        do {
            try store.save(record)
            state = .saved(record)
        } catch {
            state = .failed("寫入失敗：\(error.localizedDescription)")
        }
    }
}

struct InspectorSheet: View {
    @Bindable var model: InspectorModel
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                switch model.state {
                case .loading:
                    ProgressView("讀取分享內容…")
                case .captured(let record):
                    Section("來源標籤（整理矩陣用）") {
                        TextField("例如：Threads 單圖", text: $model.sourceLabel)
                    }
                    summary(record)
                case .saved(let record):
                    Section { Label("已記錄，可在 App 的 Debug → Payload Inspector 匯出", systemImage: "checkmark.circle") }
                    summary(record)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle("Payload Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if case .captured = model.state { Button("記錄") { model.save() } }
                }
            }
        }
    }

    private func summary(_ record: PayloadRecord) -> some View {
        Section("內容（\(record.totalDurationMs) ms）") {
            ForEach(Array(record.items.flatMap(\.attachments).flatMap(\.loads).enumerated()), id: \.offset) { _, load in
                VStack(alignment: .leading) {
                    Text(load.typeIdentifier).font(.caption.monospaced().bold())
                    Text(load.preview ?? load.error ?? load.kind.rawValue).font(.caption).lineLimit(3)
                }
            }
        }
    }
}
