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
        Text(message).foregroundStyle(.red)
    }
}

/// 地點搜尋欄：各畫面同一個元件（樣式指南「同一種物件用同一個元件」）。
public struct PlaceSearchField: View {
    @Binding var text: String
    let placeholder: String
    let isSearching: Bool
    let onSearch: () -> Void

    public init(text: Binding<String>, placeholder: String = "店名或地點", isSearching: Bool = false, onSearch: @escaping () -> Void) {
        _text = text
        self.placeholder = placeholder
        self.isSearching = isSearching
        self.onSearch = onSearch
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    public var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { if !isEmpty && !isSearching { onSearch() } }
            Button(isSearching ? "搜尋中…" : "搜尋", action: onSearch)
                .buttonStyle(.borderless)
                .disabled(isEmpty || isSearching)
        }
    }
}

/// 候選地點列：名稱＋地址，選中時打勾。
public struct PlaceOptionRow: View {
    let title: String
    let address: String?
    let selected: Bool

    public init(title: String, address: String?, selected: Bool = false) {
        self.title = title
        self.address = address
        self.selected = selected
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                if let address { Text(address).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
        }
    }
}
