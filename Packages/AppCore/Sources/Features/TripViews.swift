import AppCore
import SwiftUI

/// Trip 分頁：列出自己參與的 Trip，可建立空 Trip。
struct TripListView: View {
    let session: SessionModel
    @State private var trips: [Trip] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showsCreate = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        VStack(alignment: .leading) {
                            Text(trip.name).font(.headline)
                            Text("\(trip.startDate) – \(trip.endDate) · \(trip.timeZone)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if loaded && trips.isEmpty && errorMessage == nil {
                    ContentUnavailableView {
                        Label("尚未建立行程", systemImage: "calendar")
                    } actions: {
                        Button("建立 Trip") { showsCreate = true }
                    }
                }
            }
            .navigationTitle("Trip")
            .navigationDestination(for: Trip.self) { TripDetailView(session: session, trip: $0) }
            .toolbar {
                Button("建立 Trip", systemImage: "plus") { showsCreate = true }
            }
            .sheet(isPresented: $showsCreate) {
                CreateTripView(session: session) { trip in
                    trips.insert(trip, at: 0)
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    private func reload() async {
        do {
            trips = try await session.trips.myTrips()
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
        }
        loaded = true
    }
}

struct CreateTripView: View {
    let session: SessionModel
    let onCreated: (Trip) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var timeZoneID = "Asia/Seoul"
    @State private var errorMessage: String?
    @State private var isSaving = false

    static let timeZones = ["Asia/Seoul", "Asia/Tokyo", "Asia/Taipei"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("名稱（例如：首爾 5 天）", text: $name)
                DatePicker("開始", selection: $start, displayedComponents: .date)
                DatePicker("結束", selection: $end, in: start..., displayedComponents: .date)
                Picker("旅行地時區", selection: $timeZoneID) {
                    ForEach(Self.timeZones, id: \.self) { Text($0) }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("建立 Trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立") { Task { await save() } }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // 日期選擇器的日期以裝置時區解讀，再原樣當作旅行地的當地日期。
        let device = TimeZone.current
        do {
            let trip = try await session.trips.createTrip(
                name: name.trimmingCharacters(in: .whitespaces),
                startDate: LocalDate.string(from: start, timeZone: device),
                endDate: LocalDate.string(from: max(start, end), timeZone: device),
                timeZone: timeZoneID
            )
            onCreated(trip)
            dismiss()
        } catch let error as BackendError {
            errorMessage = switch error {
            case .unauthenticated: "登入已失效，請重新登入。"
            case .invalid(let reason): "資料不正確（\(reason)）"
            default: "建立失敗：\(error)"
            }
        } catch {
            errorMessage = "建立失敗：\(error.localizedDescription)"
        }
    }
}

/// Trip 時間軸（唯讀）。沒有 Stop 時只顯示空狀態，不畫假的 Base Route。
struct TripDetailView: View {
    let session: SessionModel
    let trip: Trip
    @State private var days: [TripDay] = []
    @State private var stopCounts: [UUID: Int] = [:]
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(days) { day in
                Section("Day \(day.displayOrder + 1) · \(day.localDate)") {
                    let count = stopCounts[day.id, default: 0]
                    if count == 0 {
                        Label("尚無行程", systemImage: "calendar.badge.plus")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(count) 個 Stop")
                    }
                    LabeledContent("路線", value: count < 2 ? "尚未建立" : "待計算")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(trip.name)
        .task {
            do {
                async let d = session.trips.days(of: trip.id)
                async let c = session.trips.stopCounts(of: trip.id)
                (days, stopCounts) = try await (d, c)
            } catch {
                errorMessage = "讀取失敗：\(error.localizedDescription)"
            }
        }
    }
}
