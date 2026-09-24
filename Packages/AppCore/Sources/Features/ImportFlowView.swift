import AppCore
import SwiftUI

/// Import → Parsing → Confirm Places → Create Trip（規格 §3.1、WP3）。
public struct ImportFlowView: View {
    let service: any ImportService
    let placeSearch: any PlaceSearching
    let onCreated: (Trip) -> Void

    @State private var session: ImportSession
    @State private var phase: Phase = .parsing
    @State private var editedText: String
    @State private var confirm: ConfirmPlacesState?
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case parsing
        case failed
        case editing
        case confirming
        case committing
    }

    public init(session: ImportSession, service: any ImportService, placeSearch: any PlaceSearching, onCreated: @escaping (Trip) -> Void) {
        self.service = service
        self.placeSearch = placeSearch
        self.onCreated = onCreated
        _session = State(initialValue: session)
        _editedText = State(initialValue: session.rawText)
    }

    public var body: some View {
        Group {
            switch phase {
            case .parsing:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在解析行程文字…")
                    Text("通常需要數十秒").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                failedView
            case .editing:
                editView
            case .confirming, .committing:
                if let confirm = Binding($confirm) {
                    ConfirmPlacesView(state: confirm, rawText: session.rawText, placeSearch: placeSearch,
                                      city: session.parseResult?.draft.cityCandidates.first,
                                      isCommitting: phase == .committing, errorMessage: errorMessage) {
                        Task { await commit() }
                    }
                }
            }
        }
        .navigationTitle(session.tripName)
        .task {
            if session.parseStatus == .parsed { apply(session) } else if phase == .parsing { await parse() }
        }
    }

    private var failedView: some View {
        Form {
            Section {
                Label("解析失敗", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failureText).foregroundStyle(.secondary)
            }
            Section("原文（已保留）") {
                Text(session.rawText).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("rawText")
            }
            Section {
                Button("重試") { Task { phase = .parsing; await parse() } }
                    .accessibilityIdentifier("retryParse")
                Button("編輯原文") { editedText = session.rawText; phase = .editing }
                Button("略過匯入，建立空 Trip") { Task { await commitEmpty() } }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
    }

    private var editView: some View {
        Form {
            Section("原文") {
                TextEditor(text: $editedText).frame(minHeight: 240)
                    .accessibilityIdentifier("rawTextEditor")
            }
            Section {
                Button("儲存並重新解析") { Task { await saveAndParse() } }
                    .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消") { phase = .failed }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
    }

    private var failureText: String {
        switch session.parseError {
        case "missing_api_key": "解析服務尚未設定（缺少 API key）。"
        case "refusal": "無法處理這段文字。"
        case "max_tokens": "文字太長，請分段匯入。"
        case "invalid_output": "解析結果格式不正確。"
        default: "暫時無法連線到解析服務。"
        }
    }

    private func parse() async {
        do {
            let updated = try await service.parse(importID: session.id)
            if updated.parseStatus == .parsed { apply(updated) } else {
                session = updated
                phase = .failed
            }
        } catch {
            phase = .failed
        }
    }

    private func apply(_ updated: ImportSession) {
        session = updated
        guard let draft = updated.parseResult?.draft else {
            phase = .failed
            return
        }
        confirm = ConfirmPlacesState(session: updated, draft: draft)
        phase = .confirming
    }

    private func saveAndParse() async {
        do {
            session = try await service.updateText(importID: session.id, rawText: editedText)
            errorMessage = nil
            phase = .parsing
            await parse()
        } catch {
            errorMessage = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private func commitEmpty() async {
        do {
            onCreated(try await service.commit(importID: session.id, days: []))
        } catch {
            errorMessage = "建立失敗：\(error.localizedDescription)"
        }
    }

    private func commit() async {
        guard let state = confirm, state.canSubmit else { return }
        phase = .committing
        do {
            var ids: [String: UUID] = [:]
            for place in state.placesToRegister {
                ids[place.providerPlaceId] = try await service.registerPlace(place).id
            }
            onCreated(try await service.commit(importID: session.id, days: state.commitDays(placeIDs: ids)))
        } catch {
            errorMessage = "建立失敗：\(error.localizedDescription)"
            phase = .confirming
        }
    }
}

struct ConfirmPlacesView: View {
    @Binding var state: ConfirmPlacesState
    let rawText: String
    let placeSearch: any PlaceSearching
    let city: String?
    let isCommitting: Bool
    let errorMessage: String?
    let onSubmit: () -> Void

    var body: some View {
        Form {
            Section {
                DisclosureGroup("原文") {
                    Text(rawText).font(.callout).textSelection(.enabled).accessibilityIdentifier("rawText")
                }
            }
            ForEach($state.items) { $item in
                Section {
                    ConfirmItemView(item: $item, tripDates: state.tripDates)
                } header: {
                    Text(item.date ?? "日期未定")
                }
            }
            Section {
                Button(isCommitting ? "建立中…" : "建立 Trip", action: onSubmit)
                    .disabled(!state.canSubmit || isCommitting)
                    .accessibilityIdentifier("submitImport")
                if !state.canSubmit {
                    Text("還有 \(state.remainingCount) 項需要確認").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("remainingCount")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .task { await searchAll() }
    }

    /// 依序查詢（MapKit 有節流）；只列候選，不自動選定。
    private func searchAll() async {
        for index in state.items.indices where !state.items[index].searched {
            let stop = state.items[index].stop
            if let query = stop.searchQuery ?? stop.placeName {
                state.items[index].candidates = await placeSearch.search(query, near: city, limit: 5)
            }
            state.items[index].searched = true
        }
    }
}

struct ConfirmItemView: View {
    @Binding var item: ConfirmItem
    let tripDates: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let start = item.stop.startTime {
                    Text(start + (item.stop.timeIsApproximate ? "（推測）" : "")).monospacedDigit()
                }
                Text(item.label).font(.headline)
            }
            Text("「\(item.stop.sourceExcerpt)」").font(.caption).foregroundStyle(.secondary)
            ForEach(item.stop.needsConfirmation, id: \.self) { reason in
                Label(reasonText(reason), systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }

        if item.date == nil || item.stop.needsConfirmation.contains(.ambiguousDate) {
            Picker("日期", selection: $item.date) {
                Text("未選").tag(String?.none)
                ForEach(tripDates, id: \.self) { Text($0).tag(Optional($0)) }
            }
        }

        if item.stop.fixedSuspected {
            Picker("固定行程？\(item.stop.fixedReason.map { "（\($0)）" } ?? "")", selection: $item.fixed) {
                Text("未確認").tag(Bool?.none)
                Text("固定").tag(Optional(true))
                Text("不固定").tag(Optional(false))
            }
            .accessibilityIdentifier("fixed-\(item.id)")
        }

        if !item.searched && item.stop.placeName != nil {
            ProgressView("搜尋候選地點…")
        }
        ForEach(item.candidates) { option in
            Button {
                item.decision = .place(option)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(option.name)
                        if let address = option.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if item.decision == .place(option) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
            }
            .accessibilityIdentifier("candidate-\(item.id)-\(option.name)")
        }
        if item.searched && item.candidates.isEmpty && item.stop.placeName != nil {
            Text("找不到符合的地點").font(.caption).foregroundStyle(.secondary)
        }

        HStack {
            Button {
                item.decision = .pendingText
            } label: {
                Label("保留為待確認文字", systemImage: item.decision == .pendingText ? "checkmark.circle.fill" : "text.bubble")
            }
            .accessibilityIdentifier("pending-\(item.id)")
            Spacer()
            Button(role: .destructive) {
                item.decision = .remove
            } label: {
                Label("移除", systemImage: item.decision == .remove ? "checkmark.circle.fill" : "trash")
            }
            .accessibilityIdentifier("remove-\(item.id)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private func reasonText(_ reason: ParsedStop.Reason) -> String {
        switch reason {
        case .ambiguousBranch: "分店不明，請選擇"
        case .unknownPlace: "可能不是可搜尋的地點"
        case .ambiguousDate: "日期不明確"
        case .ambiguousTime: "時間不明確"
        }
    }
}
