import XCTest

@MainActor
final class DashUITests: XCTestCase {
  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 10)
        || app.tabBars.firstMatch.waitForExistence(timeout: 10)
        || app.buttons["Search"].waitForExistence(timeout: 2))
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

  /// Items → feature hides the tab bar; back restores it (and detached Search).
  func testTabBarReturnsAfterItemsFeaturePop() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    let searchTab = app.tabBars.buttons["Search"]
    XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
    let itemsTab = app.tabBars.buttons["Items"]
    XCTAssertTrue(itemsTab.waitForExistence(timeout: 5))
    itemsTab.tap()
    XCTAssertTrue(app.navigationBars["Items"].waitForExistence(timeout: 5))

    let zones = app.staticTexts["Zones"].firstMatch
    XCTAssertTrue(zones.waitForExistence(timeout: 5))
    zones.tap()

    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    XCTAssertTrue(searchTab.waitForNonExistence(timeout: 2))

    back.tap()

    XCTAssertTrue(app.navigationBars["Items"].waitForExistence(timeout: 5))
    XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
  }

  /// Search → feature hides the bottom search morph with the tab bar; back
  /// restores the bottom field (not a top nav-bar search).
  func testSearchFieldStaysBottomAfterFeaturePop() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    let searchTab = app.tabBars.buttons["Search"]
    XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
    searchTab.tap()

    let searchField = app.searchFields.firstMatch
    XCTAssertTrue(searchField.waitForExistence(timeout: 5))
    let bottomYBefore = searchField.frame.midY
    XCTAssertGreaterThan(bottomYBefore, app.frame.midY)

    searchField.tap()
    searchField.typeText("zo")
    let zones = app.staticTexts["Zones"]
    XCTAssertTrue(zones.waitForExistence(timeout: 5))
    zones.tap()

    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    // Feature page: no search field and no tab-bar search morph.
    XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 2))
    XCTAssertTrue(searchTab.waitForNonExistence(timeout: 2))

    back.tap()

    // The bottom search morph returns with the tab chrome, never in the top bar.
    XCTAssertTrue(searchField.waitForExistence(timeout: 5))
    var bottomYAfter = searchField.frame.midY
    let deadline = Date().addingTimeInterval(2)
    while bottomYAfter <= app.frame.midY, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      bottomYAfter = searchField.frame.midY
    }
    XCTAssertGreaterThan(bottomYAfter, app.frame.midY)
    XCTAssertEqual(bottomYBefore, bottomYAfter, accuracy: 40)
  }
}
