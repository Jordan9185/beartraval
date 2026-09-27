import ImageIO
import PhotosUI
import ShareCore
import SwiftUI
import UniformTypeIdentifiers

/// 先存到裝置，再由既有同步流程整理；保存不等待 AI，也不要求先建立旅程。
struct InboxComposeView: View {
    let ownerHint: UUID?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var saving = false
    @State private var receipt: InboxCapture?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let receipt {
                    Section {
                        Label("已保存在此裝置", systemImage: "checkmark.circle")
                        Text(ownerHint == nil
                             ? "登入後，到分享收件匣確認匯入帳號，才會上傳與整理。"
                             : "連線後會上傳並交給 AI 整理。地點到收藏、商品到購物，行程草稿與待確認內容可在收件匣查看。")
                            .foregroundStyle(.secondary)
                        if receipt.unavailableCount > 0 {
                            Text("有 \(receipt.unavailableCount) 份附件未能取得，請稍後重新分享；其他內容已保存。")
                                .foregroundStyle(.orange)
                        }
                        Button(ownerHint == nil ? "完成" : "查看收件匣") { dismiss() }
                    }
                } else {
                    Section {
                        TextField("貼上文字、行程或連結", text: $text, axis: .vertical)
                            .lineLimit(6...12)
                            .accessibilityIdentifier("inboxComposeText")
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        PhotosPicker(selection: $photos, maxSelectionCount: 10,
                                     selectionBehavior: .ordered, matching: .images) {
                            Label(photos.isEmpty ? "選擇照片或截圖" : "已選 \(photos.count) 張照片，點此調整", systemImage: "photo.on.rectangle")
                        }
                    } footer: {
                        Text("不用先選地點或商品，也不用先建旅程。內容先保存在裝置；AI 整理後，再確認要怎麼安排。")
                    }
                    .disabled(saving)
                    if let errorMessage { ErrorText(errorMessage) }
                    Section {
                        Button(saving ? "保存中…" : "先收下") { Task { await save() } }
                            .accessibilityIdentifier("saveInboxCapture")
                            .disabled(saving || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty))
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("交給 AI 整理")
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(receipt == nil ? "取消" : "關閉") { dismiss() }.disabled(saving)
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                #endif
            }
        }
    }

    private func save() async {
        guard !saving, receipt == nil else { return }
        guard text.count <= 20_000 else {
            errorMessage = "文字超過 20,000 字，請分成幾份保存；原文仍保留在這裡。"
            return
        }
        guard let store = InboxCaptureStore.shared() else {
            errorMessage = "目前無法使用裝置儲存空間，內容尚未保存，請稍後再試。"
            return
        }
        saving = true
        errorMessage = nil
        let temporary = FileManager.default.temporaryDirectory.appending(path: "inbox-compose-\(UUID().uuidString)")
        defer {
            saving = false
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (index, photo) in photos.enumerated() {
                guard let data = try await photo.loadTransferable(type: Data.self),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let typeID = CGImageSourceGetType(source),
                      let ext = UTType(typeID as String)?.preferredFilenameExtension else {
                    throw InboxCaptureError.mediaUnavailable
                }
                guard data.count <= 30_000_000 else { throw InboxCaptureError.mediaTooLarge }
                let url = temporary.appending(path: "\(index).\(ext)")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
            receipt = try await store.capture(text: text, imageURLs: urls, ownerHint: ownerHint)
            onSaved()
        } catch InboxCaptureError.mediaTooLarge {
            errorMessage = "有照片超過 30 MB，請調整照片後再保存；文字與選取仍保留。"
        } catch {
            errorMessage = "保存未完成，文字與選取仍保留。請確認照片可讀取及裝置空間，再試一次。"
        }
    }
}
