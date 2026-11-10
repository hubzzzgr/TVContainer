import XCTest

final class TVSettingsNavigationTests: XCTestCase {
    func testLinkAfterDisabledDownload() {
        verifyLink(arguments: [])
    }

    func testLinkWhileCertificateControlsAreBusy() {
        verifyLink(arguments: ["--busy"])
    }

    private func verifyLink(arguments: [String]) {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let link = app.buttons["worthCheckingOut"]
        XCTAssertFalse(app.buttons["downloadCertificate"].isEnabled)
        // Only remote directional input; do not tap or programmatically scroll
        // the offscreen link into view.
        for _ in 0..<18 {
            if link.exists && link.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(link.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testReexecRestoresUIWithoutHomeScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--reexec-only"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Ready to restart"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Restarted in same process"].waitForExistence(timeout: 15))
        app.terminate()
    }
}
