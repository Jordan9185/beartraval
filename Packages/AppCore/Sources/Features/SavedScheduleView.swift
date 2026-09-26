import AppCore
import ShareCore
import SwiftUI

/// 收藏到旅程：使用者選日並確認；未定位可排程，但不假造路線時間。
struct SavedScheduleView: View {
    let session: SessionModel
    let entry: SavedEntry
    let onScheduled: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trip: Trip?
    @State private var days: [TripDay] = []
    @State private var stops: [Stop] = []
    @State private var matches: [UUID: DayMatch] = [:]
    @State private var selectedDayID: UUID?
    @State private var selectedByUser = false
    @State private var loading = true
    @State private var calculating = false
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var operationID = UUID()

    private var selectedDay: TripDay? { days.first { $0.id == selectedDayID } }
    private var selectedMatch: DayMatch? { selectedDayID.flatMap { matches[$0] } }

    var body: some View {
        Form {
            if let errorMessage { ErrorText(errorMessage) }
            Section("收藏的地點") {
                Text(entry.title).font(.headline)
                if let address = entry.addressLabel {
                    Text(address).font(.subheadline).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Label(entry.isConfirmed ? "已定位" : "尚未定位，排入後不計算路線",
                      systemImage: entry.isConfirmed ? "mappin.circle.fill" : "mappin.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let trip {
                Section("加入哪趟旅程") {
                    LabeledContent("旅程", value: trip.name)
                }
            }

            Section("排在哪一天") {
                if loading { ProgressView("正在載入日期…") }
                ForEach(days) { day in
                    Button {
                        selectedByUser = true
                        selectedDayID = day.id
                    } label: {
                        HStack {
                            Text("第 \(day.displayOrder + 1) 天 · \(day.localDate)")
                            Spacer()
                            if selectedDayID == day.id { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }

            if let day = selectedDay {
                Section("排入前確認") {
                    LabeledContent("日期", value: "第 \(day.displayOrder + 1) 天 · \(day.localDate)")
                    Text(routeSummary)
                        .foregroundStyle(routeHasConflict ? .orange : .secondary)
                    if let match = selectedMatch, let best = match.best {
                        Text(position(best))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if stops.contains(where: { $0.dayId == day.id && $0.fixed }) {
                        Text("已固定的行程與時間不會移動。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(submitting ? "排入中…" : "確認排到這天") { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitting)
                } footer: {
                    Text("只有按確認後才會更動旅程；無法估算路線時不顯示增加分鐘。")
                }
            }
        }
        .navigationTitle("排進旅程")
        .navigationBarTitleDisplayModeInline()
        .task { await load() }
    }

    private var routeHasConflict: Bool {
        guard let best = selectedMatch?.best else { return false }
        if case .conflict = best.fixedCheck { return true }
        return false
    }

    private var routeSummary: String {
        guard entry.place != nil else { return "地點尚未定位；會先排到這天，路線未估算。" }
        if calculating { return "正在估算路線；地點仍可先排到這天。" }
        guard let match = selectedMatch, let best = match.best,
              let minutes = best.addedTravelMinutes else {
            return "目前無法估算增加的路程；可先排入，稍後在旅程查看。"
        }
        if case .conflict(_, let late) = best.fixedCheck {
            return "約增加 \(minutes) 分路程；可能讓固定行程晚 \(late) 分，請先核對。"
        }
        return "約增加 \(minutes) 分路程，另停留 \(best.addedDwellMinutes) 分。"
    }

    private func position(_ insertion: Insertion) -> String {
        let previous = insertion.previousStopID.flatMap { id in stops.first { $0.id == id }?.rawLabel }
        let next = insertion.nextStopID.flatMap { id in stops.first { $0.id == id }?.rawLabel }
        switch (previous, next) {
        case let (p?, n?): return "排在「\(p)」和「\(n)」之間"
        case let (p?, nil): return "排在「\(p)」之後"
        case let (nil, n?): return "排在「\(n)」之前"
        default: return "排在當天最後一站"
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let tripList = session.trips.myTrips()
            async let dayList = session.trips.days(of: entry.saved.tripId)
            async let stopList = session.trips.stops(of: entry.saved.tripId)
            let (allTrips, loadedDays, loadedStops) = try await (tripList, dayList, stopList)
            trip = allTrips.first { $0.id == entry.saved.tripId }
            days = loadedDays.sorted { $0.displayOrder < $1.displayOrder }
            stops = loadedStops
            if !days.contains(where: { $0.id == selectedDayID }) {
                selectedDayID = days.first?.id
            }
            errorMessage = days.isEmpty ? "這趟旅程沒有可排入的日期。" : nil
            await calculateMatches()
        } catch {
            errorMessage = "無法載入旅程：\(userMessage(for: error))"
        }
    }

    private func calculateMatches() async {
        guard let place = entry.place else { matches = [:]; return }
        calculating = true
        defer { calculating = false }
        let ids = Array(Set(stops.compactMap(\.placeId)))
        let found = (try? await session.trips.places(ids: ids)) ?? []
        let placeByID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        let candidate = RouteCandidate(point: RoutePoint(
            coordinate: Coordinate(latitude: place.latitude, longitude: place.longitude),
            countryCode: place.countryCode), dwellMinutes: entry.saved.category.defaultDwellMinutes)
        var computed: [UUID: DayMatch] = [:]
        for day in DayTimeline.build(days: days, stops: stops) {
            guard let plan = DayPlan.from(day, places: placeByID) else { continue }
            computed[day.id] = await session.routes.match(candidate, into: plan, mode: day.day.transportMode)
        }
        matches = computed
        if !selectedByUser, let best = RouteMatcher.bestDay(Array(computed.values)) {
            selectedDayID = best.dayID
        }
    }

    private func submit() async {
        guard let day = selectedDay else { return }
        submitting = true
        defer { submitting = false }
        do {
            let best = selectedMatch?.best
            let result = try await session.trips.scheduleSaved(
                savedID: entry.id, dayID: day.id, expectedRouteRevision: day.routeRevision,
                clientOpID: operationID, beforeStopID: best?.nextStopID,
                afterStopID: best?.nextStopID == nil ? best?.previousStopID : nil)
            onScheduled(result.dayID)
            dismiss()
        } catch BackendError.staleRevision {
            await load()
            errorMessage = "旅伴剛修改了這天行程。請看更新後的日期與路線，再按一次確認。"
        } catch {
            errorMessage = "排入失敗：\(userMessage(for: error))"
        }
    }
}
