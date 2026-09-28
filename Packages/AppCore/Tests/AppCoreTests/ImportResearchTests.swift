import Foundation
import Testing
@testable import AppCore
@testable import ShareCore

/// C03 背景逐站查找：併發上限、接續同一工作、晚回結果不覆蓋、失敗不阻塞。
@MainActor
struct ImportResearchTests {
    final class Box { var state: ConfirmPlacesState; init(_ s: ConfirmPlacesState) { state = s } }

    actor FakeDiscovery: PlaceDiscovering {
        var started: [String] = []
        var statusCalls: [UUID] = []
        var active = 0
        var peak = 0
        var pendingRounds: [UUID: Int] = [:]
        var failQueries: Set<String> = []
        var jobs: [UUID: String] = [:]
        init(failQueries: Set<String> = []) { self.failQueries = failQueries }

        nonisolated func discoverPlaces(query: String, context: String) async throws -> [DiscoveredPlace] { [] }
        func startPlaceDiscovery(query: String, context: String) async throws -> PlaceDiscoveryProgress {
            started.append(query)
            active += 1; peak = max(peak, active)
            if failQueries.contains(query) { active -= 1; throw PlaceDiscoveryError.unavailable("unknown") }
            let job = UUID()
            jobs[job] = query
            pendingRounds[job] = 1
            return .pending(job)
        }
        func placeDiscoveryStatus(jobID: UUID) async throws -> PlaceDiscoveryProgress {
            statusCalls.append(jobID)
            if let rounds = pendingRounds[jobID], rounds > 0 { pendingRounds[jobID] = rounds - 1; return .pending(jobID) }
            active = max(0, active - 1)
            let name = jobs[jobID] ?? "resumed"
            return .finished([DiscoveredPlace(saved: ShoppingStoreSuggestion(name: name, koreanName: nil, addressLocal: "地址",
                searchQuery: name, reason: "來源", sourceURL: "https://example.test/\(name.count)"))])
        }
        func stats() -> (started: [String], status: [UUID], peak: Int) { (started, statusCalls, peak) }
    }

    func state(_ names: [String]) -> ConfirmPlacesState {
        let session = ImportSession(id: UUID(), tripName: "Seoul", startDate: "2026-10-01", endDate: "2026-10-01",
                                    timeZone: "Asia/Seoul", rawText: "...", parseStatus: .parsed)
        let draft = ParseDraft(days: [.init(date: "2026-10-01", dayLabel: "Day 1",
            stops: names.map { ParsedStop(sourceExcerpt: $0, placeName: $0, category: "eat") })], cityCandidates: ["Seoul"], warnings: [])
        return ConfirmPlacesState(session: session, draft: draft)
    }

    func runner(_ box: Box, _ discovery: FakeDiscovery) -> ImportResearch {
        var runner = ImportResearch(discovery: discovery, city: "Seoul",
            read: { box.state.items.indices.contains($0) ? box.state.items[$0] : nil },
            write: { index, change in change(&box.state.items[index]) })
        runner.pollInterval = .milliseconds(1)
        return runner
    }

    @Test func manyStopsRunWithBoundedConcurrencyAndPartialFailure() async {
        let names = (1...8).map { "店\($0)" }
        let box = Box(state(names))
        let discovery = FakeDiscovery(failQueries: ["店3"])
        await runner(box, discovery).runAll(Array(box.state.items.indices))
        let stats = await discovery.stats()
        #expect(stats.started.count == 8)
        #expect(stats.peak <= ImportResearch.maxConcurrent)
        #expect(box.state.items[2].researchMessage != nil && box.state.items[2].researchCandidates == nil)
        #expect(box.state.items.enumerated().filter { $0.offset != 2 }.allSatisfy { $0.element.researchCandidates?.count == 1 })
        #expect(box.state.items.allSatisfy { $0.researchJobID == nil && $0.searched })
        #expect(box.state.items.allSatisfy { $0.decision == nil })
    }

    @Test func reopenedDraftPollsSavedJobInsteadOfStartingNewOne() async {
        let box = Box(state(["店甲"]))
        let job = UUID()
        box.state.items[0].researchJobID = job
        box.state.items[0].researchRequest = UUID()
        let discovery = FakeDiscovery()
        await runner(box, discovery).runAll([0])
        let stats = await discovery.stats()
        #expect(stats.started.isEmpty)
        #expect(stats.status == [job])
        #expect(box.state.items[0].researchCandidates?.first?.name == "resumed")
    }

    @Test func lateResultForSupersededRequestIsIgnored() async {
        let box = Box(state(["店甲"]))
        let discovery = FakeDiscovery()
        let research = runner(box, discovery)
        let first = Task { await research.run(0) }
        // 使用者在舊工作回來前重新查找：換成新的要求識別。
        while box.state.items[0].researchJobID == nil { await Task.yield() }
        box.state.items[0].researchRequest = UUID()
        box.state.items[0].researchJobID = nil
        box.state.items[0].decision = .pendingText
        await first.value
        #expect(box.state.items[0].researchCandidates == nil)
        #expect(box.state.items[0].decision == .pendingText)
    }

    @Test func leavingScreenKeepsJobForResume() async {
        let box = Box(state(["店甲"]))
        let discovery = FakeDiscovery()
        var research = runner(box, discovery)
        research.pollInterval = .seconds(30)
        let task = Task { await research.run(0) }
        while box.state.items[0].researchJobID == nil { await Task.yield() }
        task.cancel()
        await task.value
        #expect(box.state.items[0].researchJobID != nil)
        #expect(box.state.items[0].needsInitialAIResearch)
        #expect(box.state.items[0].researchMessage == nil)
    }
}
