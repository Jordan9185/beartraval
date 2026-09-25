import AppCore
import ShareCore
import SwiftUI

/// 某一天的設定：交通方式與時區（跨國旅程每天可以不同）。
struct DaySettingsView: View {
    let session: SessionModel
    let day: DayTimeline
    let suggestion: String?
    let onChanged: () -> Void
    @State private var mode: TravelMode
    @State private var timeZone: String
    @State private var saving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(session: SessionModel, day: DayTimeline, suggestion: String?, onChanged: @escaping () -> Void) {
        self.session = session
        self.day = day
        self.suggestion = suggestion
        self.onChanged = onChanged
        _mode = State(initialValue: day.day.transportMode)
        _timeZone = State(initialValue: day.day.timeZone)
    }

    private var zones: [String] {
        var list = TripTimeZones.common
        for z in [day.day.timeZone, suggestion, TimeZone.current.identifier].compactMap({ $0 }) where !list.contains(z) { list.insert(z, at: 0) }
        return list
    }

    var body: some View {
        Form {
            Section {
                Picker("交通方式", selection: $mode) {
                    ForEach(TravelMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("這天的路線與順路試算都用這個交通方式。")
            }
            Section {
                Picker("時區", selection: $timeZone) {
                    ForEach(zones, id: \.self) { Text(TripTimeZones.displayName($0)).tag($0) }
                }
                if let suggestion, suggestion != timeZone {
                    Button("改成\(TripTimeZones.displayName(suggestion))") { timeZone = suggestion }
                }
            } footer: {
                Text("行程時間都是當地時間。跨國移動那天，建議設成抵達地的時區。")
            }
            if let errorMessage { ErrorText(errorMessage) }
        }
        .navigationTitle("第 \(day.day.displayOrder + 1) 天的設定")
        .toolbar {
            Button(saving ? "儲存中…" : "儲存") { Task { await save() } }
                .disabled(saving || (mode == day.day.transportMode && timeZone == day.day.timeZone))
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await session.trips.updateDay(day.id,
                                                 timeZone: timeZone == day.day.timeZone ? nil : timeZone,
                                                 transportMode: mode == day.day.transportMode ? nil : mode)
            onChanged()
            dismiss()
        } catch let error as BackendError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "儲存失敗：\(userMessage(for: error))"
        }
    }
}
