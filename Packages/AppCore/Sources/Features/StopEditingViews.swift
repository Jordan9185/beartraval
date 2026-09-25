import AppCore
import SwiftUI

/// 兩個行程點之間的這一段路程（逐段顯示，不是整天總和）。
struct LegRow: View {
    let leg: BaseRoute.Leg
    let mode: TravelMode
    let toName: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(leg.time.minutes == nil ? .orange : .secondary)
        .padding(.leading, 52)
        .accessibilityLabel(text)
    }

    private var icon: String {
        switch mode {
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        case .driving: "car.fill"
        }
    }

    private var text: String {
        let destination = toName.map { "到「\($0)」" } ?? ""
        switch leg.time {
        case .minutes(let m): return "\(mode.displayName)約 \(Int(m.rounded(.up))) 分\(destination)"
        case .unavailable(let reason):
            return reason == .notSupportedInRegion ? "\(mode.displayName)無法估算\(destination)（此地區不提供）" : "無法估算\(destination)"
        }
    }
}

/// 編輯單一行程點所需的資料（Owner／Editor；伺服器仍會檢查權限與版本）。
struct StopEditingContext {
    let session: SessionModel
    let day: DayTimeline
    /// 搜尋範圍的中心（旅程已確認地點的中心）。
    var searchCenter: Coordinate? = nil
    let onChanged: () -> Void
}

/// 待確認地點的編輯：確認地點（由使用者從候選中選）、修改文字、移除。
/// 以推進下一頁的方式呈現（在 sheet 裡再開 sheet 不可靠）。
struct PendingStopActions: View {
    let context: StopEditingContext
    let stop: Stop
    let close: () -> Void
    @State private var confirmRemove = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            NavigationLink { ResolveStopSheet(context: context, stop: stop, onDone: close) } label: {
                Label("確認地點", systemImage: "mappin.and.ellipse")
            }
            NavigationLink { RenameStopView(context: context, stop: stop, onDone: close) } label: {
                Label("修改文字", systemImage: "pencil")
            }
            Button("移除這個行程點", systemImage: "trash", role: .destructive) { confirmRemove = true }
                .confirmationDialog("移除「\(stop.rawLabel)」？", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("移除", role: .destructive) { Task { await remove() } }
                }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        } header: {
            Text("這個地點還沒確認")
        } footer: {
            Text("確認地點後才會參與路線計算。")
        }
    }

    private func remove() async {
        do {
            try await StopEditor.apply(.remove, to: stop, context: context)
            close()
        } catch let error as BackendError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "更新失敗：\(error.localizedDescription)"
        }
    }
}

struct RenameStopView: View {
    let context: StopEditingContext
    let stop: Stop
    let onDone: () -> Void
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("行程點名稱", text: $text)
            Button("儲存") { Task { await save() } }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("修改文字")
        .onAppear { text = stop.rawLabel }
    }

    private func save() async {
        do {
            try await StopEditor.apply(.rename(text), to: stop, context: context)
            onDone()
        } catch let error as BackendError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "更新失敗：\(error.localizedDescription)"
        }
    }
}

@MainActor
enum StopEditor {
    /// 以當日目前的 revision 提交；旅伴先改過時丟 `.staleRevision`，不會覆蓋。
    static func apply(_ edit: StopEdit, to stop: Stop, context: StopEditingContext) async throws {
        guard let drafts = context.day.drafts(applying: edit, to: stop.id) else { throw BackendError.notFound }
        _ = try await context.session.trips.commitItinerary(dayID: context.day.day.id,
                                                           expectedRouteRevision: context.day.day.routeRevision, stops: drafts)
        context.onChanged()
    }
}

/// 搜尋並由使用者選定地點（不自動選第一個）。
struct ResolveStopSheet: View {
    let context: StopEditingContext
    let stop: Stop
    let onDone: () -> Void
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var searching = false
    @State private var errorMessage: String?

    var body: some View {
            Form {
                Section("「\(stop.rawLabel)」") {
                    HStack {
                        TextField("店名或地點", text: $query).onSubmit { Task { await search() } }
                        Button("搜尋") { Task { await search() } }
                            .buttonStyle(.borderless)
                    }
                    if searching { ProgressView() }
                    ForEach(results) { option in
                        Button { Task { await choose(option) } } label: {
                            VStack(alignment: .leading) {
                                Text(option.displayTitle)
                                if let address = option.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("確認地點")
            .task {
                query = stop.rawLabel.replacingOccurrences(of: "（地點待確認）", with: "").replacingOccurrences(of: "（店名待確認）", with: "")
                await search()
            }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        results = await context.session.placeSearch.search(query, around: context.searchCenter, limit: 6)
        errorMessage = results.isEmpty ? "找不到符合的地點，可以換個關鍵字。" : nil
    }

    private func choose(_ option: PlaceOption) async {
        do {
            let place = try await context.session.trips.upsertPlace(option.draft)
            try await StopEditor.apply(.resolve(placeID: place.id), to: stop, context: context)
            onDone()
        } catch let error as BackendError {
            errorMessage = error.userMessage
            if error == .staleRevision { context.onChanged() }
        } catch {
            errorMessage = "更新失敗：\(error.localizedDescription)"
        }
    }
}
