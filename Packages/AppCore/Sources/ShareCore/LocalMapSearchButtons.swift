import AppCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Apple 地圖沒收錄的地點：用當地常用的地圖以名稱搜尋（韓國 Naver／Kakao，其他 Google 地圖）。
/// 只負責開啟，不讀回座標或分鐘數。
public struct LocalMapSearchButtons: View {
    let name: String
    let countryCode: String?

    public init(name: String, countryCode: String?) {
        self.name = name
        self.countryCode = countryCode
    }
    @Environment(\.openURL) private var openURL

    private var link: LocalMapLink { LocalMapLink(appName: Bundle.main.bundleIdentifier ?? "beartravel") }

    public var body: some View {
        if countryCode == "KR" {
            Button("在 Naver 地圖查看") { open(.naver) }
            Button("在 Kakao 地圖查看") { open(.kakao) }
        } else {
            Button("在 Google 地圖查看") {
                openURL(LocalMapLink.googleSearchURL(query: name, appInstalled: installed("comgooglemaps")))
            }
        }
    }

    private func open(_ app: LocalMapApp) {
        openURL(installed(app.scheme) ? link.searchURL(app, query: name) : link.webSearchURL(app, query: name))
    }

    private func installed(_ scheme: String) -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.canOpenURL(URL(string: "\(scheme)://")!)
        #else
        false
        #endif
    }
}
