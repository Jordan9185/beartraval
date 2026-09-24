import AppCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 真機驗證 Naver／Kakao 外開連結（issue #1、§4.3.1）。
///
/// 10 個首爾地點 × 兩個 App × 三種交通方式；起點固定為明洞站。
struct LocalMapLinkDebugView: View {
    @Environment(\.openURL) private var openURL
    @State private var mode: TravelMode = .transit
    @State private var withOrigin = true

    private let link = LocalMapLink(appName: Bundle.main.bundleIdentifier ?? "beartravel")
    private let origin = MapPoint(name: "명동역", latitude: 37.560_9, longitude: 126.986_3)

    var body: some View {
        List {
            Section {
                Picker("交通方式", selection: $mode) {
                    Text("大眾運輸").tag(TravelMode.transit)
                    Text("步行").tag(TravelMode.walking)
                    Text("開車").tag(TravelMode.driving)
                }
                .pickerStyle(.segmented)
                Toggle("帶起點（\(origin.name)）", isOn: $withOrigin)
                LabeledContent("Naver 已安裝", value: installed(.naver) ? "是" : "否")
                LabeledContent("Kakao 已安裝", value: installed(.kakao) ? "是" : "否")
            }
            ForEach(SeoulTestPlaces.all, id: \.name) { place in
                Section(place.name) {
                    ForEach(LocalMapApp.allCases, id: \.self) { app in
                        HStack {
                            Button(app == .naver ? "Naver 路線" : "Kakao 路線") {
                                open(link.routeURL(app, from: withOrigin ? origin : nil, to: place, mode: mode), app: app, place: place)
                            }
                            Spacer()
                            Button("搜尋") { open(link.searchURL(app, query: place.name), app: app, place: place) }
                            Button("網頁") { openURL(link.webFallbackURL(app, destination: place)) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("外開連結")
    }

    private func installed(_ app: LocalMapApp) -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.canOpenURL(URL(string: "\(app.scheme)://")!)
        #else
        false
        #endif
    }

    /// 未安裝就改開網頁版。
    private func open(_ url: URL, app: LocalMapApp, place: MapPoint) {
        openURL(installed(app) ? url : link.webFallbackURL(app, destination: place))
    }
}

enum SeoulTestPlaces {
    /// 座標為概略值；驗證重點是在地 App 能否用「名稱 + 座標」找到同一間店。
    static let all: [MapPoint] = [
        MapPoint(name: "올리브영 명동 타운", latitude: 37.563_7, longitude: 126.985_4),
        MapPoint(name: "광장시장", latitude: 37.570_0, longitude: 126.999_6),
        MapPoint(name: "경복궁", latitude: 37.579_6, longitude: 126.977_0),
        MapPoint(name: "북촌한옥마을", latitude: 37.582_6, longitude: 126.983_1),
        MapPoint(name: "동대문디자인플라자", latitude: 37.566_5, longitude: 127.009_2),
        MapPoint(name: "서울숲", latitude: 37.544_4, longitude: 127.037_4),
        MapPoint(name: "홍대입구역", latitude: 37.557_2, longitude: 126.924_5),
        MapPoint(name: "망원시장", latitude: 37.556_0, longitude: 126.906_0),
        MapPoint(name: "스타필드 코엑스몰", latitude: 37.511_5, longitude: 127.059_5),
        MapPoint(name: "롯데월드타워", latitude: 37.512_6, longitude: 127.102_5),
    ]
}
