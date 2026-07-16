import XCTest

@MainActor
final class DashUITests: XCTestCase {
  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 10)
        || app.tabBars.firstMatch.waitForExistence(timeout: 10)
        || app.buttons["Features"].waitForExistence(timeout: 2))
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

  func testPrimaryTabsAndBottomSearchSurviveFeaturePop() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
    let featuresTab = app.tabBars.buttons["Features"]
    XCTAssertTrue(featuresTab.waitForExistence(timeout: 5))
    XCTAssertTrue(app.tabBars.buttons["Watchtower"].waitForExistence(timeout: 5))
    let searchTab = app.tabBars.buttons["Search"]
    XCTAssertTrue(searchTab.waitForExistence(timeout: 5))

    featuresTab.tap()
    XCTAssertTrue(app.navigationBars["Features"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.searchFields.firstMatch.exists)

    searchTab.tap()
    let searchField = app.searchFields.firstMatch
    XCTAssertTrue(searchField.waitForExistence(timeout: 5))
    searchField.tap()
    searchField.typeText("zo")

    let zonesFeature = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Domains, DNS")
    ).firstMatch
    XCTAssertTrue(zonesFeature.waitForExistence(timeout: 5))
    zonesFeature.tap()

    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: 2))

    back.tap()

    XCTAssertTrue(searchField.waitForExistence(timeout: 5))
  }

  func testHomeShowsZonesAndShortcutsWithoutWatchtowerSummary() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    XCTAssertTrue(app.staticTexts["Your Zones"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["example.com"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Shortcuts"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["All systems normal"].exists)
  }

  func testBottomSearchOpensConcreteResource() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    let searchTab = app.tabBars.buttons["Search"]
    XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
    searchTab.tap()

    let searchField = app.searchFields.firstMatch
    XCTAssertTrue(searchField.waitForExistence(timeout: 5))
    searchField.tap()
    searchField.typeText("example")

    let zone = app.staticTexts["example.com"].firstMatch
    XCTAssertTrue(zone.waitForExistence(timeout: 5))
    zone.tap()

    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(
      searchField.waitForExistence(timeout: 5)
        || app.tabBars.buttons["Search"].waitForExistence(timeout: 5))
  }

  /// The relay keeps `/push/*` deployed for rollback, but the app must never
  /// offer it. Alerts moved from the Account feature to Watchtower in the
  /// catalog trim; the invariant did not move with them.
  func testWatchtowerAlertsDoNotExposeRemotePush() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    let watchtower = app.tabBars.buttons["Watchtower"]
    XCTAssertTrue(watchtower.waitForExistence(timeout: 5))
    watchtower.tap()

    XCTAssertFalse(app.staticTexts["Push Cloudflare alerts to this iPhone"].exists)
    XCTAssertFalse(app.buttons["Send test alert"].exists)
    XCTAssertFalse(app.switches["Push alerts"].exists)
  }
}
