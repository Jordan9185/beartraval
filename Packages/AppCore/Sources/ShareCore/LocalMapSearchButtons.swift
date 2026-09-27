import AppCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Apple 地圖沒收錄的地點：用當地常用的地圖優先以當地地址搜尋，無地址才用名稱（韓國 Naver／Kakao，其他 Google 地圖）。
/// 只負責開啟，不讀回座標或分鐘數。
public struct LocalMapSearchButtons: View {
    let name: String
    let localAddress: String?
    let countryCode: String?

    public init(name: String, localAddress: String? = nil, countryCode: String?) {
        self.name = name
        self.localAddress = localAddress
        self.countryCode = countryCode
    }
    @Environment(\.openURL) private var openURL

    private var link: LocalMapLink { LocalMapLink(appName: Bundle.main.bundleIdentifier ?? "beartravel") }

    private var query: String { LocalMapLink.preferredSearchQuery(name: name, localAddress: localAddress) }

    public var body: some View {
        if countryCode == "KR" {
            HStack(spacing: 8) {
                Button("Naver 地圖") { open(.naver) }
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button("Kakao 地圖") { open(.kakao) }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        } else {
            Button("Google 地圖") {
                openURL(LocalMapLink.googleSearchURL(query: query, appInstalled: installed("comgooglemaps")))
            }
            .frame(minHeight: 44)
            .buttonStyle(.bordered)
        }
    }

    private func open(_ app: LocalMapApp) {
        openURL(installed(app.scheme) ? link.searchURL(app, query: query) : link.webSearchURL(app, query: query))
    }

    private func installed(_ scheme: String) -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.canOpenURL(URL(string: "\(scheme)://")!)
        #else
        false
        #endif
    }
}
