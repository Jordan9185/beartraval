import XCTest

/// WP3 完成證據：歧義分店未選不能提交（AC-01）；解析失敗重試不丟原文（規格 §3.1）。
final class ImportFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestImport", scenario]
        app.launch()
        return app
    }

    /// Form 只會產生畫面內的列；往下（或往上）捲動直到元素可點。
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            up ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable", file: file, line: line)
    }

    func testSavedCardButtonsDoNotOpenDetails() {
        let app = launch("savedButtons")
        app.buttons["0 人想去"].tap()
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "詳情 0 · 想去 1 · 排程 0")
        app.buttons["排進旅程"].tap()
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "詳情 0 · 想去 1 · 排程 1")
        app.buttons["savedDetails"].tap()
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "詳情 1 · 想去 1 · 排程 1")
    }

    func testPersonalCardMapAndEditHaveSeparateTapTargets() {
        let app = launch("personalButtons")
        app.staticTexts["測試個人收藏"].tap()
        XCTAssertEqual(app.staticTexts["mapOpenCount"].label, "地圖 0")
        XCTAssertFalse(app.navigationBars["更正項目"].exists)
        app.buttons["Naver 地圖"].tap()
        XCTAssertEqual(app.staticTexts["mapOpenCount"].label, "地圖 1")
        XCTAssertEqual(app.staticTexts["mapQuery"].label, "서울 성동구 연무장길 12-1")
        XCTAssertFalse(app.navigationBars["更正項目"].exists)
        XCTAssertFalse(app.navigationBars["分享給旅伴"].exists)
        app.buttons["Kakao 地圖"].tap()
        XCTAssertEqual(app.staticTexts["mapOpenCount"].label, "地圖 2")
        XCTAssertEqual(app.staticTexts["mapQuery"].label, "서울 성동구 연무장길 12-1")
        app.buttons["更正名稱或分類"].tap()
        XCTAssertTrue(app.navigationBars["更正項目"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["分享給旅伴"].exists)
        app.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["mapOpenCount"].label, "地圖 2")
    }

    func testStartupWaitsWithoutFalseLoadFailure() {
        let app = launch("startup")
        XCTAssertTrue(app.staticTexts["載入中…"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["無法載入旅程"].exists)
        XCTAssertFalse(app.staticTexts["還沒有旅程"].exists)
        XCTAssertTrue(app.staticTexts["startupReady"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["無法載入旅程"].exists)
    }

    func testStartupRealFailureStillOffersWorkingRetry() {
        let app = launch("startupRetry")
        XCTAssertTrue(app.buttons["重新載入"].waitForExistence(timeout: 8))
        app.buttons["重新載入"].tap()
        XCTAssertTrue(app.staticTexts["載入中…"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["無法載入旅程"].exists)
        XCTAssertTrue(app.staticTexts["startupReady"].waitForExistence(timeout: 8))
    }

    func testAmbiguousBranchMustBeChosenBeforeSubmit() {
        let app = launch("ambiguous")
        let submit = app.buttons["submitImport"]

        // 名稱完全相符的地點自動選定；訂位仍要確認是否固定；分店不自動選。
        let seongsu = app.buttons["candidate-1-XXX Shoes 성수점"]
        XCTAssertTrue(seongsu.waitForExistence(timeout: 10))
        XCTAssertFalse(seongsu.images["checkmark.circle.fill"].exists, "分店不會自動選定")

        let restaurant = app.buttons["candidate-2-Some Restaurant"]
        reveal(restaurant, in: app)
        XCTAssertTrue(restaurant.images["checkmark.circle.fill"].exists, "名稱相符的地點自動選定")
        let fixed = app.buttons["fixed-2"]
        reveal(fixed, in: app)
        fixed.tap()
        app.buttons["固定"].firstMatch.tap()

        // 광장시장 名稱完全相符，收在「已自動處理」；只剩分店要選。
        let handled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "已自動處理")).firstMatch
        reveal(handled, in: app)
        XCTAssertFalse(app.buttons["candidate-0-광장시장"].exists, "自動處理的項目預設收起")

        XCTAssertFalse(submit.isEnabled, "分店未選時不能建立 Trip")
        let remaining = app.staticTexts["還有 1 項需要確認"]
        reveal(remaining, in: app)

        // 兩個分店都列出，選一個後才能提交。
        reveal(seongsu, in: app, up: true)
        XCTAssertTrue(app.buttons["candidate-1-XXX Shoes 명동점"].exists)
        seongsu.tap()

        XCTAssertTrue(submit.waitForExistence(timeout: 2))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.otherElements["tripCreated"].waitForExistence(timeout: 10)
                      || app.staticTexts["已建立 UI Test Seoul"].waitForExistence(timeout: 5))
    }

    func testParseFailureRetryKeepsRawText() {
        let app = launch("failThenSucceed")
        let retry = app.buttons["retryParse"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let raw = app.staticTexts["rawText"]
        XCTAssertTrue(raw.exists)
        XCTAssertTrue(raw.label.contains("XXX Shoes 買鞋"), "失敗後原文仍在")

        retry.tap()
        XCTAssertTrue(app.buttons["candidate-1-XXX Shoes 성수점"].waitForExistence(timeout: 10), "重試後進入確認畫面")
        app.buttons["原文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["rawText"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["rawText"].label.contains("19:00 晚餐訂位"), "重試後原文完整")
    }
    func testSourceImageOpensZoomsAndCloses() {
        let app = launch("sourceImage")
        let open = app.buttons["放大來源圖片"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let zoom = app.otherElements["sourceImageZoom"]
        let image = app.images["sourceImageContent"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        XCTAssertEqual(image.value as? String, "100%")
        zoom.doubleTap()
        let enlarged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "300%"), object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [enlarged], timeout: 3), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "來源圖片放大"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        zoom.pinch(withScale: 1.5, velocity: 1)
        XCTAssertNotEqual(image.value as? String, "300%")
        zoom.swipeUp()
        zoom.doubleTap()
        XCTAssertEqual(image.value as? String, "100%")
        app.buttons["完成"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(zoom.exists)
    }

}
