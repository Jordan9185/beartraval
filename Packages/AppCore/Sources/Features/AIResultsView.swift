import AppCore
import ShareCore
import SwiftUI

struct AIResultsLink: View {
    let session: SessionModel
    let trip: Trip
    let canEdit: Bool
    @State private var unread: Int?
    var body: some View {
        NavigationLink {
            AIResultsView(session: session, trip: trip, canEdit: canEdit)
        } label: {
            Label(unread.map { $0 > 0 ? "助理回答・\($0) 則待查看" : "已保存的助理回答" } ?? "已保存的助理回答", systemImage: "tray")
        }
        .task(id: "\(trip.id)-\(session.aiActivity.completionVersion)") {
            unread = nil
            let owner = session.trips.currentUserID
            let value = try? await session.trips.unreadAIAnswerCount(tripID: trip.id)
            guard !Task.isCancelled, session.trips.currentUserID == owner else { return }
            unread = value
        }
    }
}

private struct AIResultsView: View {
    let session: SessionModel
    let trip: Trip
    let canEdit: Bool
    @State private var records: [SavedAIAnswer] = []
    @State private var readIDs: Set<UUID> = []
    @State private var offset = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("只有你看得到這些回答。查看已保存結果不重新詢問 AI，也不自動改行程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                NavigationLink {
                    SavedAIAnswerView(session: session, trip: trip, record: record, canEdit: canEdit) {
                        readIDs.insert(record.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assistantQuestionTitle(record.question)).lineLimit(2)
                        Text("\(record.unread && !readIDs.contains(record.id) ? "待查看・" : "")\(record.created_at.prefix(10))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if loading { ProgressView("讀取已保存結果…") }
            if !loading && records.isEmpty && message == nil { Text("還沒有保存的助理回答。") }
            if let message { ErrorText(message) }
            if hasMore && !loading { Button(records.isEmpty ? "重新載入" : "載入較早結果") { Task { await load(reset: records.isEmpty) } } }
        }
        .navigationTitle("我的助理回答")
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let start = reset ? 0 : offset
            let page = try await session.trips.savedAIAnswers(tripID: trip.id, offset: start)
            guard !Task.isCancelled else { return }
            let existing = reset ? [] : records
            let ids = Set(existing.map(\.id))
            records = existing + page.filter { !ids.contains($0.id) }
            offset = start + page.count
            hasMore = page.count == 50
            message = nil
        } catch { message = userMessage(for: error) }
    }
}

private struct SavedAIAnswerView: View {
    let session: SessionModel
    let trip: Trip
    let record: SavedAIAnswer
    let canEdit: Bool
    let onRead: () -> Void
    @State private var readError: String?
    var body: some View {
        List {
            Section {
                Text(assistantQuestionTitle(record.question))
                Text("保存於 \(record.created_at.prefix(10))；內容依當時行程產生，安排前請核對目前日期與資料。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let answer = record.answer, record.status == "answered" {
                Section("已保存的回答") {
                    if answer.cannotDetermine { Text("當時資料不足，無法確認。") }
                    Text(answer.answer)
                }
                ForEach(Array((answer.recommendations ?? []).enumerated()), id: \.offset) { _, candidate in
                    RestaurantAnswerRow(candidate: candidate, checkedAt: answer.checkedAt)
                }
                if !(answer.arrangements ?? []).isEmpty && canEdit {
                    NavigationLink("用目前行程核對這份安排") {
                        TripAIPlanView(session: session, trip: trip, savedAnswer: answer) { }
                    }
                }
                if let packing = answer.packingSuggestions, !packing.isEmpty {
                    Section("當時的用品建議") {
                        ForEach(Array(packing.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.name) × \(item.quantity)")
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink("開啟目前用品清單") { PackingView(session: session, trip: trip, canEdit: canEdit) }
                }
            } else { Text("這次沒有產生可用的回答，原問題仍保留。") }
            if let readError { ErrorText(readError) }
        }
        .navigationTitle("AI 結果")
        .task {
            guard record.unread else { return }
            do { try await session.trips.markAIAnswerRead(id: record.id); onRead() }
            catch { readError = "已讀狀態尚未同步：\(userMessage(for: error))" }
        }
    }
}


/// 系統產生的提示保留在原紀錄，畫面不顯示格式欄位與派送指令。
private func assistantQuestionTitle(_ question: String) -> String {
    if question == PackingSuggestions.question { return "旅行用品建議" }
    if question.hasPrefix("請為這趟旅程尚未安排的收藏與商品彙整 arrangements") {
        if let marker = question.range(of: "補充要求：", options: .backwards) {
            let instruction = question[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !instruction.isEmpty { return "整趟旅程的安排建議：\(instruction)" }
        }
        return "整趟旅程的安排建議"
    }
    if question.hasPrefix("請以本站為中心，搜尋到訪當天附近的熱門景點") { return "本站附近探索" }
    return question
}
