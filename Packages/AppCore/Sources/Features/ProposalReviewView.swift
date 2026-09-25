import AppCore
import ShareCore
import SwiftUI

/// 加入行程前的確認（AC-08）：先顯示路程、停留與固定行程衝突，按確認才新增 Stop。
/// 當日已被他人修改時（AC-13），顯示重新計算的結果並要求再確認一次。
struct ProposalReviewView: View {
    let session: SessionModel
    let tripID: UUID
    let dayID: UUID
    let dayTitle: String
    let mode: TravelMode
    let candidate: SearchResult
    let dwellMinutes: Int
    /// 建立 Purchase Stop 時的商品（WP8）。
    var shoppingItemID: UUID? = nil
    /// AI 助手建議的變更（仍需使用者確認）。
    var createdByAI = false
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .preparing
    @State private var pending: AddToDayFlow.Pending?
    @State private var notice: String?

    enum Phase: Equatable {
        case preparing
        case review
        case confirming
        case unavailable
        case failed(String)
    }

    private var flow: AddToDayFlow {
        AddToDayFlow(service: session.trips, matcher: session.routes)
    }

    var body: some View {
        NavigationStack {
            Form {
                if createdByAI {
                    Section { Label("AI 助手的建議，確認後才會加入。", systemImage: "sparkles").font(.caption) }
                }
                if let notice {
                    Section {
                        Label(notice, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    }
                }
                switch phase {
                case .preparing:
                    ProgressView("以最新行程計算中…")
                case .unavailable:
                    Text("以最新行程重新計算後，這天已無法估算，所以不能加入。").foregroundStyle(.secondary)
                case .failed(let message):
                    ErrorText(message)
                case .review, .confirming:
                    if let pending {
                        Section("\(dayTitle)（\(mode.displayName)）") {
                            LabeledContent("地點", value: candidate.draft.displayTitle)
                            Text(position(pending))
                            MatchNumbers(insertion: pending.insertion) { pending.stopLabels[$0 ?? UUID()] }
                        }
                        Section {
                            Button(phase == .confirming ? "加入中…" : "確認加入") { Task { await confirm() } }
                                .disabled(phase == .confirming)
                        } footer: {
                            Text("按確認後才會新增到正式行程。")
                        }
                    }
                }
            }
            .navigationTitle("加入行程")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if let id = pending?.proposal.id { Task { try? await session.trips.reject(proposalID: id) } }
                        dismiss()
                    }
                }
            }
            .task { await prepare() }
        }
    }

    private func position(_ pending: AddToDayFlow.Pending) -> String {
        let prev = pending.insertion.previousStopID.flatMap { pending.stopLabels[$0] }
        let next = pending.insertion.nextStopID.flatMap { pending.stopLabels[$0] }
        switch (prev, next) {
        case let (p?, n?): return "插在「\(p)」和「\(n)」之間"
        case let (p?, nil): return "排在「\(p)」之後"
        case let (nil, n?): return "排在「\(n)」之前"
        default: return "當天第一站"
        }
    }

    private func prepare() async {
        do {
            let place = try await session.trips.upsertPlace(candidate.draft)
            let (fresh, _) = try await flow.propose(placeID: place.id, label: place.displayTitle, point: candidate.point,
                                                    dwellMinutes: dwellMinutes, tripID: tripID, dayID: dayID, mode: mode,
                                                    shoppingItemID: shoppingItemID, createdByAI: createdByAI)
            pending = fresh
            phase = fresh == nil ? .unavailable : .review
        } catch {
            phase = .failed("無法建立加入要求：\(userMessage(for: error))")
        }
    }

    private func confirm() async {
        guard let current = pending else { return }
        phase = .confirming
        do {
            switch try await flow.confirm(current, point: candidate.point) {
            case .added:
                onAdded()
            case .needsReconfirm(let fresh):
                pending = fresh
                notice = "行程剛被其他人修改。以下是依最新行程重新計算的結果，請再確認一次。"
                phase = .review
            case .noLongerAvailable:
                pending = nil
                notice = "行程剛被其他人修改。"
                phase = .unavailable
            }
        } catch let error as BackendError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("加入失敗：\(userMessage(for: error))")
        }
    }
}
