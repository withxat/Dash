import XCTest

@MainActor
final class DashUITests: XCTestCase {
  /// Pin English so zh-Hans String Catalog never breaks label assertions.
  private static let englishLaunchArguments = [
    "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ui-testing",
  ]

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

  private func openDNSRecordAndDelete(_ recordID: String, in app: XCUIApplication) {
    let record = app.buttons["dns-record-\(recordID)"]
    XCTAssertTrue(record.waitForExistence(timeout: 5))
    for _ in 0..<5 where !record.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(Self.waitForHittable(record))
    record.tap()

    let delete = app.buttons["dash-tray-header-delete"]
    XCTAssertTrue(Self.waitForHittable(delete))
    delete.tap()
  }

  func testLaunchesWithDashBrand() {
    let app = XCUIApplication()
    launch(app)
    XCTAssertTrue(
      app.staticTexts["Dash"].waitForExistence(timeout: 10)
        || app.buttons["Resources"].waitForExistence(timeout: 10))
  }

  func testOnboardingRequestsFullAccessAndDefersNotifications() {
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
    let fullAccessLabel = NSPredicate(format: "label CONTAINS[c] %@", "Read & write")
    let fullAccessExpectation = XCTNSPredicateExpectation(
      predicate: fullAccessLabel,
      object: cloudflare)
    XCTAssertEqual(
      XCTWaiter.wait(for: [fullAccessExpectation], timeout: 2),
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

  func testTrayCloseDismissesKeyboardAndCover() {
    let app = XCUIApplication()
    launch(app, arguments: ["-uiTestKeyboardForm"])

    let nameField = app.textFields["Name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))
    nameField.tap()

    let keyboard = app.keyboards.firstMatch
    let card = app.descendants(matching: .any)["dash.tray.card"].firstMatch
    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
    XCTAssertTrue(card.exists)
    XCTAssertTrue(close.waitForExistence(timeout: 2))

    close.tap()

    XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
    XCTAssertTrue(card.waitForNonExistence(timeout: 2))
  }

  func testTrayStopsAnchoredMotionWhenReduceMotionTurnsOn() {
    let app = XCUIApplication()
    launch(app, arguments: ["-uiTestTrayMotion"])

    let source = app.buttons["ui-test-tray-source"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.tap()

    let card = app.descendants(matching: .any)["dash.tray.card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 2))
    let anchored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "anchored"), object: card)
    XCTAssertEqual(XCTWaiter.wait(for: [anchored], timeout: 2), .completed)

    let enableReduceMotion = app.buttons["ui-test-enable-reduce-motion"]
    XCTAssertTrue(Self.waitForHittable(enableReduceMotion))
    enableReduceMotion.tap()

    let released = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "unanchored"), object: card)
    XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 2), .completed)

    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 2))
    close.tap()
    XCTAssertTrue(card.waitForNonExistence(timeout: 2))
    let restoredSource = app.buttons["Open anchored tray"]
    XCTAssertTrue(restoredSource.waitForExistence(timeout: 2))
    restoredSource.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(card.waitForExistence(timeout: 2))
  }

  func testR2CreateSuccessFlightSurvivesKeyboardDismissal() {
    let app = XCUIApplication()
    launch(app, arguments: ["-uiTestR2TrayFlight"])

    let source = app.buttons["ui-test-r2-create-source"]
    XCTAssertTrue(Self.waitForHittable(source))
    source.tap()

    let name = app.textFields["Bucket name"]
    XCTAssertTrue(Self.waitForHittable(name))
    name.tap()
    name.typeText("ui-bucket")
    XCTAssertTrue(app.keyboards.firstMatch.exists)

    let create = app.buttons["Create bucket"]
    XCTAssertTrue(Self.waitForHittable(create))
    create.tap()

    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Created successfully."].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Success flight ran"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Bucket created"].waitForExistence(timeout: 3))
    let restoredSource = app.buttons["Open R2 create"]
    XCTAssertTrue(restoredSource.waitForExistence(timeout: 2))
    restoredSource.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.textFields["Bucket name"].waitForExistence(timeout: 2))
  }

  func testDeferredDNSDeletionHidesImmediatelyAndUndoRestoresIt() {
    let app = XCUIApplication()
    launch(
      app,
      arguments: [
        "-uiTestDeferredDeletion",
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
      ])

    let record = app.buttons["dns-record-record-1"]
    openDNSRecordAndDelete("record-1", in: app)

    XCTAssertTrue(record.waitForNonExistence(timeout: 2))
    let undo = app.buttons["dash-toast-action"]
    XCTAssertTrue(Self.waitForHittable(undo))
    XCTAssertTrue(undo.label.contains("Undo"))
    XCTAssertGreaterThanOrEqual(undo.frame.height, 44)

    undo.tap()

    XCTAssertTrue(record.waitForExistence(timeout: 2))
  }

  func testDeferredDNSDeletionRollsIntoOneUndoAllBatch() {
    let app = XCUIApplication()
    launch(app, arguments: ["-uiTestDeferredDeletion"])

    openDNSRecordAndDelete("record-1", in: app)
    openDNSRecordAndDelete("record-2", in: app)

    XCTAssertTrue(app.buttons["dns-record-record-1"].waitForNonExistence(timeout: 2))
    XCTAssertTrue(app.buttons["dns-record-record-2"].waitForNonExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["No DNS records"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.staticTexts["Record types"].exists)
    let undoAll = app.buttons["dash-toast-action"]
    XCTAssertTrue(Self.waitForHittable(undoAll))
    XCTAssertTrue(undoAll.label.contains("Undo all"))

    undoAll.tap()

    XCTAssertTrue(app.buttons["dns-record-record-1"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["dns-record-record-2"].waitForExistence(timeout: 2))
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
    XCTAssertTrue(app.buttons["home-quick-purge-cache"].exists)
    XCTAssertTrue(app.buttons["home-quick-enable-under-attack-mode"].exists)
    XCTAssertTrue(app.buttons["home-quick-upload-r2"].exists)

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

  func testHomeQuickActionOpensPurgeCacheTray() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let purgeCache = app.buttons["home-quick-purge-cache"]
    XCTAssertTrue(purgeCache.waitForExistence(timeout: 5))
    purgeCache.tap()

    XCTAssertTrue(
      app.staticTexts["Choose the domain whose cache you want to clear."]
        .waitForExistence(timeout: 5))
    XCTAssertFalse(purgeCache.isHittable)

    let card = app.descendants(matching: .any)["dash.tray.card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 2))
    let anchored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "anchored"), object: card)
    XCTAssertEqual(XCTWaiter.wait(for: [anchored], timeout: 2), .completed)

    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 2))
    close.tap()

    XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    let restoredPurgeCache = app.buttons["Purge cache"]
    XCTAssertTrue(restoredPurgeCache.waitForExistence(timeout: 2))

    restoredPurgeCache.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let zone = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "example.com")
    ).firstMatch
    XCTAssertTrue(Self.waitForHittable(zone))
    zone.tap()

    XCTAssertTrue(card.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Purge URL"].waitForExistence(timeout: 5))
  }

  func testProfileTrayStackRetargetsCloseControlToBack() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let profile = app.buttons["header-profile-button"]
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    profile.press(forDuration: 0.8)

    // Root step: the tray's dismissal circle is a close button.
    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["dash.tray.back"].exists)

    // Push the switch-account detail step.
    let inactiveAccount = app.buttons["profile-account-demo-account-studio"]
    XCTAssertTrue(Self.waitForHittable(inactiveAccount))
    inactiveAccount.tap()

    // Detail step: the same circle wearing the same ✕, now doing the back
    // job (only the label and identifier say so) — and no footer Cancel whose
    // only job is going back.
    let back = app.buttons["dash.tray.back"]
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["dash.tray.close"].exists)
    XCTAssertFalse(app.buttons["Cancel"].exists)

    // Back pops to the root step; the tray stays presented.
    back.tap()
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["profile-account-sign-out"].waitForExistence(timeout: 5))

    // Close on the root dismisses the whole tray.
    close.tap()
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: close)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
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

  /// Watchtower presents Cloudflare history; delivery controls live in Settings.
  func testWatchtowerAlertsDoNotExposeRemotePush() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let watchtower = app.buttons["Watchtower"]
    XCTAssertTrue(watchtower.waitForExistence(timeout: 5))
    watchtower.tap()

    XCTAssertFalse(app.staticTexts["Push Cloudflare alerts to this iPhone"].exists)
    XCTAssertFalse(app.switches["Push alerts"].exists)
    XCTAssertFalse(app.staticTexts["Recent alerts"].exists)

    let inbox = app.buttons["watchtower-inbox-button"]
    XCTAssertTrue(inbox.waitForExistence(timeout: 5))
    inbox.tap()
    XCTAssertTrue(app.staticTexts["Alerts"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Inbox"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["History"].exists)
    XCTAssertTrue(app.buttons["Ignored"].exists)

    // The preview inbox is Cloudflare-only: one delivery is unread and one is
    // the explicitly seeded first-page history baseline.
    let tunnelAlert = app.buttons["watchtower-inbox-cf:ui-alert-1"]
    XCTAssertTrue(tunnelAlert.waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.buttons.matching(
        NSPredicate(format: "identifier CONTAINS %@", "dash:live:")
      ).firstMatch.exists)
    tunnelAlert.tap()
    XCTAssertTrue(
      app.buttons["watchtower-inbox-ignore-toggle"].waitForExistence(timeout: 5))
  }

  func testSettingsExposesDefaultAlertPoliciesAndICloudSync() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let profile = app.buttons["header-profile-button"]
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    profile.tap()

    XCTAssertTrue(app.buttons["settings-profile-row"].waitForExistence(timeout: 5))

    let iCloudSync = app.switches["icloud-settings-sync"]
    for _ in 0..<4 where !iCloudSync.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(Self.waitForHittable(iCloudSync))
    XCTAssertEqual(iCloudSync.value as? String, "On")
    iCloudSync.tap()
    let syncOff = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Off"),
      object: iCloudSync)
    XCTAssertEqual(XCTWaiter.wait(for: [syncOff], timeout: 5), .completed)

    XCTAssertTrue(Self.waitForHittable(iCloudSync))
    iCloudSync.tap()
    let syncOn = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "On"),
      object: iCloudSync)
    XCTAssertEqual(XCTWaiter.wait(for: [syncOn], timeout: 5), .completed)

    let alertPolicies =
      app.descendants(matching: .any)
      .matching(identifier: "Alert policies")
      .firstMatch
    for _ in 0..<5 where !alertPolicies.exists {
      app.swipeUp()
    }
    XCTAssertTrue(alertPolicies.waitForExistence(timeout: 5))
  }

  func testAvatarOpensSettingsWithProfileAsAChildPage() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let headerProfile = app.buttons["header-profile-button"]
    XCTAssertTrue(headerProfile.waitForExistence(timeout: 5))
    headerProfile.tap()

    let profileRow = app.buttons["settings-profile-row"]
    XCTAssertTrue(profileRow.waitForExistence(timeout: 5))
    profileRow.tap()

    XCTAssertTrue(app.staticTexts["User ID"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Registered"].waitForExistence(timeout: 5))
  }

  func testResourcesR2OpensBucketListAndPopsBack() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let r2 = app.buttons["feature-r2"]
    XCTAssertTrue(Self.waitForHittable(r2))
    r2.tap()

    let assetsBucket = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH[c] %@", "assets,")
    ).firstMatch
    XCTAssertTrue(assetsBucket.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    let back = app.buttons["Back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }

  func testSettingsExperimentalShowsFeatureToggles() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let profile = app.buttons["header-profile-button"]
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    profile.tap()

    let registrarToggle = app.switches["settings-experimental-registrar"]
    let tunnelsToggle = app.switches["settings-experimental-tunnels"]
    // The deterministic preview now includes the account-switching row. The
    // lazy stack can therefore expose this element to accessibility before it
    // is on screen; scroll until it is actually tappable, not merely present.
    for _ in 0..<6 where !tunnelsToggle.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(registrarToggle.waitForExistence(timeout: 5))
    XCTAssertTrue(Self.waitForHittable(registrarToggle))
    XCTAssertTrue(tunnelsToggle.waitForExistence(timeout: 5))
    XCTAssertTrue(Self.waitForHittable(tunnelsToggle))
  }

  func testResourcesRegistrarCatalogOpens() {
    let app = XCUIApplication()
    launch(
      app,
      arguments: [
        "-ui-preview", "-dash.experimental.registrar_enabled", "YES",
      ])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let registrar = app.buttons["feature-registrar"]
    XCTAssertTrue(Self.waitForHittable(registrar))
    registrar.tap()

    let exampleDomain = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "example.com")
    ).firstMatch
    XCTAssertTrue(exampleDomain.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    let back = app.buttons["Back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }

  func testResourcesEmailRoutingCatalogOpens() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let emailRouting = app.buttons["feature-emailRouting"]
    XCTAssertTrue(Self.waitForHittable(emailRouting))
    emailRouting.tap()

    let exampleDomain = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "example.com")
    ).firstMatch
    XCTAssertTrue(exampleDomain.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    let back = app.buttons["Back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }
}
