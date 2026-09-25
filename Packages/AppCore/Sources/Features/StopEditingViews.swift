import AppCore
import ShareCore
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
        .accessibilityLabel(mode.displayName + text)
    }

    private var icon: String {
        switch mode {
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        case .driving: "car.fill"
        }
    }

    private var text: String {
        // 交通方式由前面的圖示表達，不再重複寫字（樣式指南）。
        let destination = toName.map { "到「\($0)」" } ?? ""
        switch leg.time {
        case .minutes(let m): return "約 \(Int(m.rounded(.up))) 分\(destination)"
        case .unavailable(let reason):
            return reason == .notSupportedInRegion ? "無法估算\(destination)（此地區不提供）" : "無法估算\(destination)"
        }
    }
}

/// 編輯單一行程點所需的資料（Owner／Editor；伺服器仍會檢查權限與版本）。
struct StopEditingContext {
    let session: SessionModel
    let day: DayTimeline
    /// 搜尋範圍：同一天的地點優先，其次旅程其他區域。
    var searchAreas: SearchAreas = .none
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
                Label("在 Apple 地圖定位", systemImage: "mappin.and.ellipse")
            }
            NavigationLink { RenameStopView(context: context, stop: stop, onDone: close) } label: {
                Label("修改文字", systemImage: "pencil")
            }
            Button("移除這個行程點", systemImage: "trash", role: .destructive) { confirmRemove = true }
                .confirmationDialog("移除「\(stop.rawLabel)」？", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("移除", role: .destructive) { Task { await remove() } }
                }
            if let errorMessage { ErrorText(errorMessage) }
        } header: {
            Text("編輯")
        } footer: {
            Text("在 Apple 地圖定位後，才會計入路線時間。")
        }
    }

    private func remove() async {
        do {
            try await StopEditor.apply(.remove, to: stop, context: context)
            close()
        } catch let error as BackendError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "更新失敗：\(userMessage(for: error))"
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
            if let errorMessage { ErrorText(errorMessage) }
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
            errorMessage = "更新失敗：\(userMessage(for: error))"
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
                    PlaceSearchField(text: $query, isSearching: searching) { Task { await search() } }
                    if searching { ProgressView() }
                    ForEach(results) { option in
                        Button { Task { await choose(option) } } label: {
                            PlaceOptionRow(title: option.displayTitle, address: option.address)
                        }
                    }
                }
                if let errorMessage { ErrorText(errorMessage) }
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
        results = await context.session.placeSearch.search(query, in: context.searchAreas, limit: 6)
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
            errorMessage = "更新失敗：\(userMessage(for: error))"
        }
    }
}

/// 要比較交通方式的那一段路。
struct LegComparison: Identifiable {
    let id = UUID()
    let from: Place
    let to: Place
    let departure: Date
    let dayID: UUID
    let current: TravelMode

    /// 以這天當地的出發時間查詢（沒有時間就用 10:00）；已過去的時間改用現在。
    static func departure(day: TripDay, from stop: Stop) -> Date {
        guard let tz = TimeZone(identifier: day.timeZone), let midnight = LocalDate.midnight(day.localDate, in: tz) else { return Date() }
        let minutes = stop.startTime.flatMap(LocalTime.minutes).map { $0 + (stop.dwellMinutes ?? 0) } ?? 10 * 60
        return max(midnight.addingTimeInterval(Double(minutes) * 60), Date())
    }
}

/// 同一段路三種交通方式比較（步行／大眾運輸／開車・計程車），可把這天改用其中一種。
struct LegModesView: View {
    let session: SessionModel
    let leg: LegComparison
    let canEdit: Bool
    let onChanged: () -> Void
    @State private var results: [(mode: TravelMode, time: LegTime)] = []
    @State private var saving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(leg.from.displayTitle) → \(leg.to.displayTitle)").font(.subheadline)
                }
                Section {
                    if results.isEmpty { ProgressView("計算中…") }
                    ForEach(results, id: \.mode) { result in
                        HStack {
                            Label(result.mode.displayName, systemImage: result.mode.symbol)
                            Spacer()
                            Text(Self.text(result.time)).foregroundStyle(result.time.minutes == nil ? .secondary : .primary).monospacedDigit()
                            if result.mode == leg.current { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("這天目前用的") }
                        }
                    }
                } footer: {
                    Text("計程車時間約等於開車，不含等車與塞車變化。算不出的就顯示無法估算，不用直線距離推算。")
                }
                if leg.from.isInKorea || leg.to.isInKorea {
                    Section("大眾運輸在韓國請用當地地圖查") {
                        LocalMapButtons(destination: leg.to.mapPoint, origin: leg.from.mapPoint, mode: .transit, address: leg.to.address)
                    }
                }
                if canEdit {
                    Section {
                        ForEach(TravelMode.allCases.filter { $0 != leg.current }, id: \.self) { mode in
                            Button("這天改用\(mode.displayName)") { Task { await apply(mode) } }.disabled(saving)
                        }
                    } footer: {
                        Text("改的是這一天所有路段的計算方式；旅伴也會看到。")
                    }
                }
                if let errorMessage { ErrorText(errorMessage) }
            }
            .navigationTitle("交通方式比較")
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                let from = RoutePoint(coordinate: Coordinate(latitude: leg.from.latitude, longitude: leg.from.longitude), countryCode: leg.from.countryCode)
                let to = RoutePoint(coordinate: Coordinate(latitude: leg.to.latitude, longitude: leg.to.longitude), countryCode: leg.to.countryCode)
                results = await session.routes.compareModes(from: from, to: to, departure: leg.departure)
            }
        }
    }

    static func text(_ time: LegTime) -> String {
        switch time {
        case .minutes(let m): return "約 \(Int(m.rounded(.up))) 分"
        case .unavailable(let reason): return reason == .notSupportedInRegion ? "無法估算（此地區不提供）" : "無法估算"
        }
    }

    private func apply(_ mode: TravelMode) async {
        saving = true
        defer { saving = false }
        do {
            _ = try await session.trips.updateDay(leg.dayID, transportMode: mode)
            onChanged()
            dismiss()
        } catch {
            errorMessage = "更新失敗：\(userMessage(for: error))"
        }
    }
}

extension TravelMode {
    var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        case .driving: "car.fill"
        }
    }
}
