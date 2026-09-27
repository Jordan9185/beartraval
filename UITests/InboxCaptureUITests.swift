import XCTest

/// 走真正 RootView 的無帳號入口（含未設定整理服務）；只保存合成文字到測試裝置，不建立帳號或呼叫 AI。
final class InboxCaptureUITests: XCTestCase {
    func testCaptureNeedsNeitherLoginNorTrip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let collect = app.buttons["先收下旅行資料"]
        XCTAssertTrue(collect.waitForExistence(timeout: 15))
        collect.tap()
        let save = app.buttons["saveInboxCapture"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "空白內容不能假裝已保存")

        let field = app.descendants(matching: .any).matching(identifier: "inboxComposeText").firstMatch
        field.tap()
        field.typeText("Tokyo five days\nhttps://example.com/travel-test")
        app.toolbars.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["已保存在此裝置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["登入後，到分享收件匣確認匯入帳號，才會上傳與整理。"].exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "未登入收件成功"
        receipt.lifetime = .keepAlways
        add(receipt)
        app.buttons["關閉"].tap()
        XCTAssertTrue(collect.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["內容已保存在此裝置。登入後，到分享收件匣確認匯入目前帳號。"].exists)
    }
}
