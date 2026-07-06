import XCTest

final class DashUITests: XCTestCase {
  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 5)
        || app.tabBars.firstMatch.waitForExistence(timeout: 5))
  }
}
