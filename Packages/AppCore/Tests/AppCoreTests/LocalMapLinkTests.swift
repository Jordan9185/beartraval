import Foundation
import Testing
@testable import AppCore

struct LocalMapLinkTests {
    let link = LocalMapLink(appName: "com.example.beartravel")
    let myeongdong = MapPoint(name: "명동역", latitude: 37.5609, longitude: 126.9863)
    let ddp = MapPoint(name: "동대문디자인플라자", latitude: 37.5665, longitude: 127.0092)

    @Test func naverRouteCarriesOriginDestinationModeAndAppName() throws {
        let url = link.routeURL(.naver, from: myeongdong, to: ddp, mode: .transit)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.scheme == "nmap")
        #expect(c.host == "route")
        #expect(c.path == "/public")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(q["slat"] == "37.560900")
        #expect(q["slng"] == "126.986300")
        #expect(q["sname"] == "명동역")
        #expect(q["dlat"] == "37.566500")
        #expect(q["dname"] == "동대문디자인플라자")
        #expect(q["appname"] == "com.example.beartravel")
    }

    @Test(arguments: [(TravelMode.walking, "/walk"), (.driving, "/car"), (.transit, "/public")])
    func naverModePath(mode: TravelMode, path: String) {
        let url = link.routeURL(.naver, from: nil, to: ddp, mode: mode)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == path)
    }

    @Test func naverRouteWithoutOriginOmitsStartParameters() throws {
        let url = link.routeURL(.naver, from: nil, to: ddp, mode: .walking)
        let names = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map(\.name)
        #expect(!names.contains("slat"))
        #expect(!names.contains("sname"))
        #expect(names.contains("dlat"))
    }

    @Test(arguments: [(TravelMode.walking, "FOOT"), (.driving, "CAR"), (.transit, "PUBLICTRANSIT")])
    func kakaoRoute(mode: TravelMode, by: String) throws {
        let url = link.routeURL(.kakao, from: myeongdong, to: ddp, mode: mode)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.scheme == "kakaomap")
        #expect(c.host == "route")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(q["sp"] == "37.560900,126.986300")
        #expect(q["ep"] == "37.566500,127.009200")
        #expect(q["by"] == by)
    }

    @Test func searchURLsPercentEncodeKoreanNames() {
        let naver = link.searchURL(.naver, query: "올리브영 명동")
        let kakao = link.searchURL(.kakao, query: "올리브영 명동")
        #expect(naver.absoluteString.hasPrefix("nmap://search?query=%EC%98%AC"))
        #expect(kakao.absoluteString.hasPrefix("kakaomap://search?q=%EC%98%AC"))
    }

    @Test func addressSearchPreservesLocalTextAcrossAppsAndWeb() throws {
        let address = "서울 성동구 연무장길 12-1, 2층"
        let query = LocalMapLink.preferredSearchQuery(name: "同名店", localAddress: "  \(address)\n")
        #expect(query == address)
        for app in LocalMapApp.allCases {
            let url = link.searchURL(app, query: query)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.first { $0.name == (app == .naver ? "query" : "q") }?.value == address)
            let web = try #require(URLComponents(url: link.webSearchURL(app, query: query), resolvingAgainstBaseURL: false))
            if app == .naver { #expect(web.path == "/p/search/" + address) }
            else { #expect(web.queryItems?.first { $0.name == "q" }?.value == address) }
        }
        for installed in [true, false] {
            let google = try #require(URLComponents(url: LocalMapLink.googleSearchURL(query: query, appInstalled: installed), resolvingAgainstBaseURL: false))
            #expect(google.queryItems?.first { $0.name == (installed ? "q" : "query") }?.value == address)
        }
    }

    @Test(arguments: [nil, "", "  \n\t"] as [String?])
    func missingAddressFallsBackToName(address: String?) {
        #expect(LocalMapLink.preferredSearchQuery(name: "  무구옥 성수점  ", localAddress: address) == "무구옥 성수점")
    }

    @Test func kakaoWebFallbackStripsCommasFromName() {
        let point = MapPoint(name: "Cafe, Seoul", latitude: 37.5, longitude: 127.0)
        let url = link.webFallbackURL(.kakao, destination: point)
        #expect(url.absoluteString == "https://map.kakao.com/link/to/Cafe%20%20Seoul,37.500000,127.000000")
    }
}
