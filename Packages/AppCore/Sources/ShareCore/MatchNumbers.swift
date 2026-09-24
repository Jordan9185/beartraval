import AppCore
import SwiftUI

/// 三個分開的數字：路程、停留、固定行程餘裕（§4.2）。
public struct MatchNumbers: View {
    let insertion: Insertion
    let stopName: (UUID?) -> String?

    public init(insertion: Insertion, stopName: @escaping (UUID?) -> String?) {
        self.insertion = insertion
        self.stopName = stopName
    }

    public var body: some View {
        LabeledContent("路程", value: insertion.addedTravelMinutes.map { "+\($0) 分" } ?? "無法估算")
        LabeledContent("停留", value: "+\(insertion.addedDwellMinutes) 分")
        LabeledContent("固定行程") {
            switch insertion.fixedCheck {
            case .noFixedAfter: Text("之後沒有固定行程")
            case .slack(let id, let m): Text("距「\(stopName(id) ?? "固定行程")」還有 \(m) 分")
            case .conflict(let id, let m): Text("「\(stopName(id) ?? "固定行程")」會遲到 \(m) 分").foregroundStyle(.red)
            case .unknown: Text("缺少時間，無法判斷")
            }
        }
        if insertion.approximate {
            Text("當天行程較多，只精算了部分位置。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension AddToDayFlow.Pending {
    public var positionText: String {
        let prev = insertion.previousStopID.flatMap { stopLabels[$0] }
        let next = insertion.nextStopID.flatMap { stopLabels[$0] }
        switch (prev, next) {
        case let (p?, n?): return "插在「\(p)」和「\(n)」之間"
        case let (p?, nil): return "排在「\(p)」之後"
        case let (nil, n?): return "排在「\(n)」之前"
        default: return "當天第一站"
        }
    }
}
