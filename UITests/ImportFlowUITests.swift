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

    func testAmbiguousBranchMustBeChosenBeforeSubmit() {
        let app = launch("ambiguous")
        let submit = app.buttons["submitImport"]

        // 候選出現後，除了分店外其他都先決定。
        let market = app.buttons["candidate-0-광장시장"]
        XCTAssertTrue(market.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["candidate-1-XXX Shoes 성수점"].images["checkmark.circle.fill"].exists, "分店不會自動選定")
        market.tap()

        let restaurant = app.buttons["candidate-2-Some Restaurant"]
        reveal(restaurant, in: app)
        restaurant.tap()
        let fixed = app.buttons["fixed-2"]
        reveal(fixed, in: app)
        fixed.tap()
        app.buttons["固定"].firstMatch.tap()

        reveal(submit, in: app)
        XCTAssertFalse(submit.isEnabled, "分店未選時不能建立 Trip")
        XCTAssertTrue(app.staticTexts["還有 1 項需要確認"].exists)

        // 兩個分店都列出，選一個後才能提交。
        let seongsu = app.buttons["candidate-1-XXX Shoes 성수점"]
        reveal(seongsu, in: app, up: true)
        XCTAssertTrue(app.buttons["candidate-1-XXX Shoes 명동점"].exists)
        seongsu.tap()

        reveal(submit, in: app)
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
        XCTAssertTrue(app.buttons["candidate-0-광장시장"].waitForExistence(timeout: 10), "重試後進入確認畫面")
        app.buttons["原文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["rawText"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["rawText"].label.contains("19:00 晚餐訂位"), "重試後原文完整")
    }
}
