import AppCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 「給司機看」全螢幕卡片：上半部大字給司機（當地語言），下半部中文對照給使用者確認。
struct TaxiCardView: View {
    let card: TaxiCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 給司機看：只有兩層字級，店名最大，其餘同一級。
                VStack(alignment: .leading, spacing: 16) {
                    Text(card.request)
                        .font(.system(size: 26))
                    Text(card.name)
                        .font(.system(size: 40, weight: .heavy))
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    if let address = card.address {
                        Text(address)
                            .font(.system(size: 26))
                            .textSelection(.enabled)
                    }
                    ForEach(Array(card.extras.enumerated()), id: \.offset) { _, extra in
                        Text(extra.local).font(.system(size: 26))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("taxiLocal")

                // 給使用者確認
                VStack(alignment: .leading, spacing: 8) {
                    Label("中文對照（請先確認內容正確）", systemImage: "checkmark.shield")
                        .font(.body.weight(.semibold))
                    LabeledContent("請求", value: card.requestZh)
                    LabeledContent("目的地", value: card.nameZh ?? "（沒有中文名稱）")
                    if card.address == nil { LabeledContent("地址", value: "（沒有地址）") }
                    ForEach(Array(card.extras.enumerated()), id: \.offset) { _, extra in
                        LabeledContent("補充", value: extra.zh)
                    }
                    ForEach(card.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("taxiChinese")
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
        }
        #if canImport(UIKit)
        // 出示給司機時螢幕不要自動變暗。
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }
}

/// 「給司機看」按鈕；需要有已確認的地點。
struct TaxiCardButton: View {
    let card: TaxiCard
    @State private var showing = false

    init(place: Place, fallbackChineseLabel: String? = nil) {
        card = TaxiCard(place: place, fallbackChineseLabel: fallbackChineseLabel)
    }

    /// 未定位的地點：只用名稱。
    init(unlocatedName name: String, countryCode: String?) {
        card = TaxiCard(unlocatedName: name, countryCode: countryCode)
    }

    var body: some View {
        Button("給計程車司機看", systemImage: "car.fill") { showing = true }
            .fullScreenCoverCompat(isPresented: $showing) {
                TaxiCardView(card: card)
            }
    }
}

extension View {
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
