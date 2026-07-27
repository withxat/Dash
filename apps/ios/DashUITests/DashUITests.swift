import XCTest

@MainActor
final class DashUITests: XCTestCase {
  /// Pin English so zh-Hans String Catalog never breaks label assertions.
  private static let englishLaunchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

  private func launch(_ app: XCUIApplication, arguments: [String] = []) {
    app.launchArguments = Self.englishLaunchArguments + arguments
    app.launch()
  }

  static func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"),
      object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    launch(app)
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 10)
        || app.buttons["Resources"].waitForExistence(timeout: 10))
  }

  func testOnboardingStartsReadOnlyAndDefersNotifications() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview-onboarding"])

    let start = app.buttons["Start your engine!"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    let legal = app.staticTexts["By continuing, you agree to our"]
    XCTAssertTrue(legal.waitForExistence(timeout: 2))
    let buttonFrame = start.frame
    let legalFrame = legal.frame
    start.tap()

    XCTAssertTrue(app.staticTexts["Connect safely"].waitForExistence(timeout: 5))
    let connect = app.buttons["Connect Cloudflare"]
    XCTAssertTrue(connect.exists)
    XCTAssertFalse(app.buttons["Review permissions"].exists)
    XCTAssertEqual(buttonFrame.minY, connect.frame.minY, accuracy: 1)
    XCTAssertEqual(
      legalFrame.minY,
      app.staticTexts["By continuing, you agree to our"].frame.minY,
      accuracy: 1
    )

    let cloudflare =
      app.descendants(matching: .any)
      .matching(identifier: "onboarding-permission-cloudflare")
      .firstMatch
    let network = app.buttons["onboarding-permission-network"]
    XCTAssertTrue(cloudflare.waitForExistence(timeout: 5))
    XCTAssertTrue(network.waitForExistence(timeout: 5))
    let readOnlyLabel = NSPredicate(format: "label CONTAINS[c] %@", "Read only first")
    let readOnlyExpectation = XCTNSPredicateExpectation(
      predicate: readOnlyLabel,
      object: cloudflare)
    XCTAssertEqual(
      XCTWaiter.wait(for: [readOnlyExpectation], timeout: 2),
      .completed,
      "Unexpected Cloudflare row label: \(cloudflare.label)")
    XCTAssertFalse(app.buttons["onboarding-permission-notifications"].exists)
    // Network auto-probes on appear; non-China / simulator settles to Enabled.
    let networkEnabled = network.label.contains("Enabled")
    let networkSettling =
      network.label.contains("Requesting") || network.label.contains("Tap to enable")
    if !networkEnabled {
      XCTAssertTrue(networkSettling)
      let enabled = NSPredicate(format: "label CONTAINS[c] %@", "Enabled")
      expectation(for: enabled, evaluatedWith: network)
      waitForExpectations(timeout: 10)
    }
    let back = app.buttons["onboarding-back"]
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.tap()
    XCTAssertTrue(app.staticTexts["Dash"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Start your engine!"].exists)
    XCTAssertEqual(
      legalFrame.minY,
      app.staticTexts["By continuing, you agree to our"].frame.minY,
      accuracy: 1
    )
  }

  func testFormKeyboardCanBeDismissed() {
    let app = XCUIApplication()
    launch(app, arguments: ["-uiTestKeyboardForm"])

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

  func testPrimaryTabsSurviveFeaturePop() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
    let resourcesTab = app.buttons["Resources"]
    XCTAssertTrue(resourcesTab.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Watchtower"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Search"].exists)

    resourcesTab.tap()

    let zonesFeature = app.buttons["feature-zones"]
    XCTAssertTrue(Self.waitForHittable(zonesFeature))
    zonesFeature.tap()

    // Feature detail is a system push; the catalog root has no navigation
    // title, so the native back button reads "Back".
    let back = app.buttons["Back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    // Feature detail immerses — the floating tab bar leaves the hierarchy.
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    back.tap()

    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }

  func testWatchtowerChartsCanBeReorderedByLongPress() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let watchtower = app.buttons["Watchtower"]
    XCTAssertTrue(Self.waitForHittable(watchtower))
    watchtower.tap()

    let editCharts = app.buttons["Edit charts"]
    XCTAssertTrue(Self.waitForHittable(editCharts))
    editCharts.tap()

    let addChart = app.buttons["watchtower-add-chart"]
    XCTAssertTrue(Self.waitForHittable(addChart))

    let webTraffic = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Web Traffic,")
    ).firstMatch
    let clientErrors = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Client Request Errors,")
    ).firstMatch
    XCTAssertTrue(webTraffic.waitForExistence(timeout: 5))
    XCTAssertTrue(clientErrors.waitForExistence(timeout: 5))

    let originalWebTrafficY = webTraffic.frame.minY
    let source = webTraffic.coordinate(
      withNormalizedOffset: CGVector(dx: 0.35, dy: 0.65))
    let destination = clientErrors.coordinate(
      withNormalizedOffset: CGVector(dx: 0.35, dy: 0.65))
    source.press(forDuration: 0.8, thenDragTo: destination)

    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        webTraffic.frame.minY > originalWebTrafficY + 20
      },
      object: webTraffic)
    XCTAssertEqual(
      XCTWaiter.wait(for: [moved], timeout: 3),
      .completed,
      "Long-pressing a chart should start the native drag and reorder it."
    )

    app.buttons["watchtower-customize-cancel"].tap()
  }

  func testNavigationDrillDownWorkersAndBack() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let workers = app.buttons["feature-workers"]
    XCTAssertTrue(Self.waitForHittable(workers))
    workers.tap()

    // Prefer the hittable row on the active stack — inactive tabs can still
    // expose identically labeled elements to XCTest.
    let worker = app.buttons["worker-api-worker"]
    XCTAssertTrue(Self.waitForHittable(worker))
    worker.tap()

    let deployments = app.staticTexts["Deployments"]
    XCTAssertTrue(deployments.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    // Leading-edge swipe pops the Worker detail.
    let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
    let interior = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
    edge.press(forDuration: 0.05, thenDragTo: interior)

    let workerAgain = app.buttons["worker-api-worker"]
    XCTAssertTrue(Self.waitForHittable(workerAgain))
    XCTAssertTrue(deployments.waitForNonExistence(timeout: 2))

    // Back to Resources catalog — the untitled catalog root leaves the feature
    // screen's native back button labeled "Back".
    let backToCatalog = app.buttons["Back"].firstMatch
    XCTAssertTrue(backToCatalog.waitForExistence(timeout: 5))
    backToCatalog.tap()
    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }

  /// Expands the collapsed Domains group on Home, scrolling it into reach
  /// first when large type pushes it below the fold.
  private func expandHomeDomains(in app: XCUIApplication) {
    let toggle = app.buttons["home-domains-toggle"]
    if !toggle.waitForExistence(timeout: 2) {
      for _ in 0..<3 where !toggle.exists { app.swipeUp() }
    }
    XCTAssertTrue(toggle.waitForExistence(timeout: 3))
    if !toggle.isHittable { app.swipeUp() }
    toggle.tap()
  }

  func testHomeZoneOpensDomainDetail() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    expandHomeDomains(in: app)
    let domainRow = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "example.com")
    ).firstMatch
    XCTAssertTrue(domainRow.waitForExistence(timeout: 5))
    domainRow.tap()

    let back = app.buttons["Back"].firstMatch
    let customize = app.buttons["domain-card-customize"]
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    XCTAssertTrue(customize.waitForExistence(timeout: 5))
    XCTAssertTrue(back.isHittable)
    XCTAssertTrue(customize.isHittable)
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    // Returning surfaces the visit under Recently used; Domains expand morph
    // still owns the zone identities on Home.
    back.tap()
    XCTAssertTrue(app.staticTexts["Recently used"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Domain"].firstMatch.exists)
  }

  func testHomeShowsGreetingQuickActionsAndCollapsedDomains() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    XCTAssertTrue(app.staticTexts["What are we doing today?"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["home-quick-add-domain"].exists)
    XCTAssertTrue(app.buttons["home-quick-upload-r2"].exists)
    XCTAssertTrue(app.buttons["home-quick-add-dns"].exists)

    // Domains ships collapsed: the group header is there, zone names are not.
    let domainsToggle = app.buttons["home-domains-toggle"]
    if !domainsToggle.exists { app.swipeUp() }
    XCTAssertTrue(domainsToggle.waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["example.com"].exists)

    XCTAssertTrue(app.staticTexts["Shortcuts"].exists)
    XCTAssertTrue(app.buttons["Edit"].exists)
    // Recently used stays hidden until a resource has been opened.
    XCTAssertFalse(app.staticTexts["Recently used"].exists)
    XCTAssertFalse(app.staticTexts["Account status"].exists)
    XCTAssertFalse(app.buttons["home-watchtower-summary"].exists)

    expandHomeDomains(in: app)
    XCTAssertTrue(app.staticTexts["example.com"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["docs.example.com"].exists)
    XCTAssertFalse(app.staticTexts["View all domains"].exists)
  }

  func testHomeQuickActionOpensAddDomainTray() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let addDomain = app.buttons["home-quick-add-domain"]
    XCTAssertTrue(addDomain.waitForExistence(timeout: 5))
    addDomain.tap()

    XCTAssertTrue(app.textFields["Domain"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts
        .matching(NSPredicate(format: "label CONTAINS[c] %@", "name servers"))
        .firstMatch.exists)
  }

  func testDomainCardColorCanBeCustomized() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    expandHomeDomains(in: app)
    let domainRow = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "example.com")
    ).firstMatch
    XCTAssertTrue(domainRow.waitForExistence(timeout: 5))
    domainRow.tap()

    let customize = app.buttons["domain-card-customize"]
    XCTAssertTrue(customize.waitForExistence(timeout: 5))
    customize.tap()

    let close = app.buttons["domain-card-customize-close"]
    let save = app.buttons["domain-card-customize-save"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.otherElements["Color palette"].waitForExistence(timeout: 5)
        || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "card preview"))
          .firstMatch.waitForExistence(timeout: 5)
    )
    close.tap()
    XCTAssertTrue(app.buttons["domain-card-customize"].waitForExistence(timeout: 5))
  }

  func testHomeListsResourcesAtAccessibilityTextSizes() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview", "-ui-preview-accessibility-text"])

    XCTAssertTrue(app.staticTexts["Domains"].waitForExistence(timeout: 5))
    expandHomeDomains(in: app)
    XCTAssertTrue(app.staticTexts["example.com"].waitForExistence(timeout: 5))
  }

  func testWorkerDetailShowsLatestActiveDeployment() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let workers = app.buttons["feature-workers"]
    XCTAssertTrue(Self.waitForHittable(workers))
    workers.tap()

    let worker = app.buttons["worker-api-worker"]
    XCTAssertTrue(Self.waitForHittable(worker))
    worker.tap()

    XCTAssertTrue(app.staticTexts["Deployments"].waitForExistence(timeout: 5))
    // "Current", not "Active" — the badge names which deployment is live, and
    // Dash spends "Active" on zone / R2-domain health.
    XCTAssertTrue(app.staticTexts["Current"].exists)
  }

  /// Push alerts live in Settings — Watchtower stays local-only.
  func testWatchtowerAlertsDoNotExposeRemotePush() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let watchtower = app.buttons["Watchtower"]
    XCTAssertTrue(watchtower.waitForExistence(timeout: 5))
    watchtower.tap()

    XCTAssertFalse(app.staticTexts["Push Cloudflare alerts to this iPhone"].exists)
    XCTAssertFalse(app.buttons["Send test alert"].exists)
    XCTAssertFalse(app.switches["Push alerts"].exists)
    XCTAssertFalse(app.staticTexts["Recent alerts"].exists)

    let inbox = app.buttons["watchtower-inbox-button"]
    XCTAssertTrue(inbox.waitForExistence(timeout: 5))
    inbox.tap()
    XCTAssertTrue(app.staticTexts["Alerts"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Inbox"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["History"].exists)
    XCTAssertTrue(app.buttons["Ignored"].exists)

    // Live Dash warnings land in the inbox as normal rows.
    let tunnelAlert = app.buttons.matching(
      NSPredicate(format: "identifier CONTAINS %@", "dash:live:tunnels")
    ).firstMatch
    XCTAssertTrue(tunnelAlert.waitForExistence(timeout: 5))
    tunnelAlert.tap()
    XCTAssertTrue(app.staticTexts["Tunnels"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Ignore"].waitForExistence(timeout: 5))
  }

  func testSettingsExposesPushAlerts() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let profile = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Profile,")
    ).firstMatch
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    profile.tap()

    let settings = app.buttons["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.tap()

    XCTAssertTrue(app.staticTexts["Push alerts"].waitForExistence(timeout: 5))
    // DashToggleRow combines title + switch into one accessibility element.
    XCTAssertTrue(
      app.buttons["Push alerts"].exists || app.switches["Push alerts"].exists)
  }
}
