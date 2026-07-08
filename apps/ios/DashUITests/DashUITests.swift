import XCTest

@MainActor
final class DashUITests: XCTestCase {
  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 5)
        || app.tabBars.firstMatch.waitForExistence(timeout: 5))
  }

  func testFormKeyboardCanBeDismissed() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTestKeyboardForm"]
    app.launch()

    let nameField = app.textFields["Name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))

    nameField.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 2))
    nameField.typeText("\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))

    nameField.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
    app.staticTexts["Form background"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
  }
}
