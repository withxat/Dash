import XCTest

@MainActor
final class DashUITests: XCTestCase {
  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 10)
        || app.tabBars.firstMatch.waitForExistence(timeout: 10)
        || app.buttons["Resources"].waitForExistence(timeout: 2))
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
    let resourcesTab = app.tabBars.buttons["Resources"]
    XCTAssertTrue(resourcesTab.waitForExistence(timeout: 5))
    XCTAssertTrue(app.tabBars.buttons["Watchtower"].waitForExistence(timeout: 5))
    let searchTab = app.tabBars.buttons["Search"]
    XCTAssertTrue(searchTab.waitForExistence(timeout: 5))

    resourcesTab.tap()
    XCTAssertTrue(app.navigationBars["Resources"].waitForExistence(timeout: 5))
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

  func testHomeShowsOperationalSummaryWithoutShortcutDuplication() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    XCTAssertTrue(app.staticTexts["Your Zones"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["example.com"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Account status"].waitForExistence(timeout: 5))
    let summary = app.buttons["home-watchtower-summary"]
    XCTAssertTrue(summary.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Shortcuts"].exists)
    summary.tap()
    XCTAssertTrue(app.navigationBars["Watchtower"].waitForExistence(timeout: 5))
  }

  func testHomeZonesOverscrollPastEndOpensAllZones() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    let strip = app.scrollViews["home-zones-strip"]
    XCTAssertTrue(strip.waitForExistence(timeout: 5))

    // Resource screens title themselves with an inline principal view, so the
    // pushed screen is detected by title text scoped to the navigation bar.
    let pushedTitle = app.navigationBars.staticTexts["Zones"]

    // One fling from the strip's start cannot overscroll while the finger is
    // down (a page of content remains), and its bounce off the end happens
    // after the finger lifts — so it must stay a scroll. A second fling could
    // legitimately trigger mid-drag, so only one is safe to assert on.
    strip.swipeLeft()
    XCTAssertFalse(pushedTitle.exists)

    // One sustained drag through the end and past the trailing edge opens
    // the full list.
    let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    let end = strip.coordinate(withNormalizedOffset: CGVector(dx: -1.5, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

    XCTAssertTrue(pushedTitle.waitForExistence(timeout: 5))
  }

  func testHomeZonesShortStripPullOpensAllZonesWithoutScrollableContent() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview", "-ui-preview-two-zones"]
    app.launch()

    let strip = app.scrollViews["home-zones-strip"]
    XCTAssertTrue(strip.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["docs.example.com"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["api.example.net"].exists)

    let pushedTitle = app.navigationBars.staticTexts["Zones"]
    XCTAssertFalse(pushedTitle.exists)

    // With nothing to scroll the strip still bounces, so one sustained pull
    // past the trailing edge opens the full list.
    let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    let end = strip.coordinate(withNormalizedOffset: CGVector(dx: -1.5, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

    XCTAssertTrue(pushedTitle.waitForExistence(timeout: 5))
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

  func testHomeZonesUseReadableRowsAtAccessibilityTextSizes() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-preview",
      "-ui-preview-accessibility-text",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["example.com"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["docs.example.com"].exists)
    XCTAssertFalse(app.scrollViews["home-zones-strip"].exists)
  }

  func testWorkerDetailShowsLatestActiveDeployment() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-preview"]
    app.launch()

    let resources = app.tabBars.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let workers = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Scripts, metrics")
    ).firstMatch
    XCTAssertTrue(workers.waitForExistence(timeout: 5))
    workers.tap()

    let worker = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "api-worker")
    ).firstMatch
    XCTAssertTrue(worker.waitForExistence(timeout: 5))
    worker.tap()

    XCTAssertTrue(app.staticTexts["Latest deployment"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Serving production traffic"].exists)
    XCTAssertTrue(app.staticTexts["Active"].exists)
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
    XCTAssertFalse(app.staticTexts["Recent alerts"].exists)

    let tunnelActions = app.buttons["watchtower-actions-tunnels"]
    XCTAssertTrue(tunnelActions.waitForExistence(timeout: 5))
    tunnelActions.tap()
    XCTAssertTrue(app.staticTexts["Tunnels"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Suggested action"].exists)
    XCTAssertTrue(app.buttons["Mute for 24 hours"].exists)
  }
}
