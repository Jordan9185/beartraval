import XCTest

/// WP8：未選店前是「未安排」（AC-09）；勾選已購買更新進度、可撤銷誤勾（AC-11）。
final class ShoppingUITests: XCTestCase {
    func testAddPurchaseAndUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestShopping", "1"]
        app.launch()

        let field = app.textFields["newItemField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("ReFa CARAT")
        app.buttons["addItem"].tap()

        let status = app.staticTexts["status-ReFa CARAT"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "未安排")
        XCTAssertTrue(app.staticTexts["已買 0／1"].exists)

        app.buttons["purchase-ReFa CARAT"].tap()
        XCTAssertTrue(app.staticTexts["已買 1／1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["status-ReFa CARAT"].label.hasPrefix("你已購買"))

        // 撤銷誤勾。
        app.buttons["purchase-ReFa CARAT"].tap()
        XCTAssertTrue(app.staticTexts["已買 0／1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["status-ReFa CARAT"].label, "未安排")
    }
}
