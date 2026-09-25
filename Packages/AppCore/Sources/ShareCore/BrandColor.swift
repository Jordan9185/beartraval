import SwiftUI

extension Color {
    /// 品牌主色：熊毛棕（D13）。App 用 Asset Catalog 的 AccentColor；Share Extension
    /// 沒有 Asset Catalog，用這個設 tint。兩處數值相同。
    public static let bearBrown = Color(light: (0x9A, 0x64, 0x40), dark: (0xC8, 0x92, 0x5F))

    init(light: (Int, Int, Int), dark: (Int, Int, Int)) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        })
        #else
        self.init(red: Double(light.0) / 255, green: Double(light.1) / 255, blue: Double(light.2) / 255)
        #endif
    }
}

/// 錯誤訊息的共用樣式：紅字、內文字級、無圖示（樣式指南）。
public struct ErrorText: View {
    let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        ErrorText(message)
    }
}
