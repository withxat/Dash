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

  func testOnboardingUsesOnePageWithDirectCloudflareAction() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview-onboarding"])

    XCTAssertTrue(app.staticTexts["Dash"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Cloudflare,"].exists)
    XCTAssertTrue(app.staticTexts["in your hand"].exists)
    XCTAssertTrue(app.staticTexts["By continuing, you agree to our"].exists)

    let connect = app.buttons["onboarding-connect"]
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Connect Cloudflare")
    XCTAssertTrue(app.buttons["Explore the demo"].exists)

    XCTAssertFalse(app.staticTexts["Connect safely"].exists)
    XCTAssertFalse(app.buttons["onboarding-back"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["onboarding-permission-cloudflare"].exists)
    XCTAssertFalse(app.buttons["onboarding-permission-network"].exists)
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

  func testSingleEndedTraySourceFallsBackToStandardReveal() {
    let app = XCUIApplication()
    launch(app, arguments: ["-uiTestTrayMotion"])

    let source = app.buttons["ui-test-tray-source"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.tap()

    let card = app.descendants(matching: .any)["dash.tray.card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 2))
    let standard = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "standard"), object: card)
    XCTAssertEqual(XCTWaiter.wait(for: [standard], timeout: 2), .completed)

    let enableReduceMotion = app.buttons["ui-test-enable-reduce-motion"]
    XCTAssertTrue(Self.waitForHittable(enableReduceMotion))
    enableReduceMotion.tap()

    XCTAssertEqual(card.value as? String, "standard")

    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 2))
    close.tap()
    XCTAssertTrue(card.waitForNonExistence(timeout: 2))
    let restoredSource = app.buttons["Open anchored tray"]
    XCTAssertTrue(restoredSource.waitForExistence(timeout: 2))
    restoredSource.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(card.waitForExistence(timeout: 2))
  }

  func testDemoConnectUsesPairedRevealAndRestoresSource() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview-onboarding"])

    let exploreDemo = app.buttons["Explore the demo"]
    XCTAssertTrue(exploreDemo.waitForExistence(timeout: 5))
    // iOS 26.4 can report this visible text-only SwiftUI button as not
    // hittable even after the splash handoff. Let that handoff settle, then
    // keep the downstream behavior assertions authoritative.
    _ = Self.waitForHittable(exploreDemo)
    exploreDemo.tap()

    let source = app.buttons["home-demo-connect"]
    XCTAssertTrue(source.waitForExistence(timeout: 10))
    XCTAssertTrue(Self.waitForHittable(source))
    source.tap()

    let card = app.descendants(matching: .any)["dash.tray.card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 2))
    let paired = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "paired"), object: card)
    XCTAssertEqual(XCTWaiter.wait(for: [paired], timeout: 2), .completed)

    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(Self.waitForHittable(close))
    XCTAssertEqual(card.value as? String, "paired")
    close.tap()

    XCTAssertTrue(card.waitForNonExistence(timeout: 5))
    XCTAssertTrue(source.waitForExistence(timeout: 2))
    XCTAssertTrue(Self.waitForHittable(source))
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

    // Feature detail is owned by Dash's page stack and exposes one stable Back.
    let back = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    // Feature detail immerses — the floating tab bar leaves the hierarchy.
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    back.tap()

    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }

  func testDomainsGroupingActionStaysHittableAcrossReentry() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(Self.waitForHittable(resources))
    resources.tap()

    let zones = app.buttons["feature-zones"]
    XCTAssertTrue(Self.waitForHittable(zones))
    zones.tap()
    XCTAssertTrue(app.buttons["dash.navigation.back"].waitForExistence(timeout: 5))
    app.buttons["dash.navigation.back"].tap()

    XCTAssertTrue(Self.waitForHittable(zones))
    zones.tap()
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(format: "label CONTAINS[c] %@", "example.com")
      ).firstMatch.waitForExistence(timeout: 5)
    )

    let grouping = app.buttons["domains-group-by-status"]
    XCTAssertTrue(Self.waitForHittable(grouping))
    XCTAssertTrue(grouping.isEnabled)
    let initialLabel = grouping.label
    let targetLabel =
      initialLabel == "Group by status" ? "Show ungrouped" : "Group by status"
    grouping.tap()
    let changedLabel = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", targetLabel),
      object: grouping)
    XCTAssertEqual(XCTWaiter.wait(for: [changedLabel], timeout: 2), .completed)
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

    let backFromWorker = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(backFromWorker.waitForExistence(timeout: 5))
    backFromWorker.tap()

    let workerAgain = app.buttons["worker-api-worker"]
    XCTAssertTrue(Self.waitForHittable(workerAgain))
    XCTAssertTrue(deployments.waitForNonExistence(timeout: 2))

    // Back once more from the Workers collection to the Resources root.
    let backToCatalog = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(backToCatalog.waitForExistence(timeout: 5))
    backToCatalog.tap()
    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }

  func testNavigationDrillDownPagesCardAndBack() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let resources = app.buttons["Resources"]
    XCTAssertTrue(resources.waitForExistence(timeout: 5))
    resources.tap()

    let pages = app.buttons["feature-pages"]
    XCTAssertTrue(Self.waitForHittable(pages))
    pages.tap()

    let project = app.buttons["pages-project-marketing-site"]
    XCTAssertTrue(Self.waitForHittable(project))
    project.tap()

    XCTAssertTrue(app.staticTexts["Domains"].waitForExistence(timeout: 5))
    let back = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()

    XCTAssertTrue(Self.waitForHittable(app.buttons["pages-project-marketing-site"]))
  }

  func testPagesResourceCardGrowsAndStaysSemanticAtAccessibilityTextSize() {
    let app = XCUIApplication()
    launch(
      app,
      arguments: [
        "-ui-preview",
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
      ])

    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
    app.buttons["Resources"].tap()
    let pages = app.buttons["feature-pages"]
    XCTAssertTrue(Self.waitForHittable(pages))
    pages.tap()

    let projectID = "pages-project-documentation-with-a-long-project-name"
    let project = app.buttons[projectID]
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    for _ in 0..<4 where !project.isHittable { app.swipeUp() }
    XCTAssertTrue(Self.waitForHittable(project))
    XCTAssertEqual(
      project.label,
      "documentation-with-a-long-project-name, Pages, documentation-preview.pages.dev, Status, In progress"
    )
    XCTAssertEqual(app.buttons.matching(identifier: projectID).count, 1)
    XCTAssertGreaterThan(project.frame.width, app.windows.firstMatch.frame.width * 0.8)
    XCTAssertGreaterThan(project.frame.height, 116)

    project.tap()
    XCTAssertTrue(app.staticTexts["Domains"].waitForExistence(timeout: 5))
    let back = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(project.waitForExistence(timeout: 5))
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

    let back = app.buttons["dash.navigation.back"].firstMatch
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
    XCTAssertTrue(app.buttons["home-quick-enable-under-attack-mode"].exists)
    XCTAssertTrue(app.buttons["home-quick-upload-r2"].exists)
    XCTAssertTrue(app.buttons["home-quick-add-domain"].exists)

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
    let pinnedDomain = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "example.com")
    ).firstMatch
    XCTAssertTrue(pinnedDomain.label.contains("Pinned"))
    XCTAssertFalse(app.staticTexts["View all domains"].exists)
  }

  func testHomeQuickActionUsesStandardTrayReveal() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let underAttack = app.buttons["home-quick-enable-under-attack-mode"]
    XCTAssertTrue(underAttack.waitForExistence(timeout: 5))
    underAttack.tap()

    XCTAssertTrue(
      app.staticTexts["Choose the domain to update."]
        .waitForExistence(timeout: 5))
    XCTAssertFalse(underAttack.isHittable)

    let card = app.descendants(matching: .any)["dash.tray.card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 2))
    let standard = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "standard"), object: card)
    XCTAssertEqual(XCTWaiter.wait(for: [standard], timeout: 2), .completed)

    let close = app.buttons["dash.tray.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 2))
    close.tap()

    XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    let restoredUnderAttack = app.buttons["Under Attack"]
    XCTAssertTrue(restoredUnderAttack.waitForExistence(timeout: 2))

    restoredUnderAttack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let zone = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "example.com")
    ).firstMatch
    XCTAssertTrue(Self.waitForHittable(zone))
    zone.tap()

    XCTAssertTrue(app.buttons["Enable Under Attack"].waitForExistence(timeout: 5))
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
    XCTAssertTrue(Self.waitForHittable(save))
    save.tap()
    XCTAssertTrue(save.waitForNonExistence(timeout: 5))
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

  /// Watchtower presents Cloudflare history without exposing remote push controls.
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
    let title = app.staticTexts["dash.navigation.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.label, "Alerts")
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

  func testGlowInspirationReturnsToTheSameCenteredCard() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let profile = app.buttons["header-profile-button"]
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    profile.tap()

    let glow = app.buttons["workspace-glow-color"]
    XCTAssertTrue(Self.waitForHittable(glow))
    glow.tap()

    let ember = app.buttons["workspace-glow-preset-orange"]
    let none = app.buttons["workspace-glow-preset-none"]
    let inspiration = app.buttons["workspace-glow-inspiration-orange"]
    XCTAssertTrue(Self.waitForHittable(none))
    XCTAssertTrue(Self.waitForHittable(ember))
    XCTAssertTrue(Self.waitForHittable(inspiration))

    // The stored preview starts on Ember. Its first rendered position must
    // already agree with that selection, before a tap creates a new scroll
    // target edge and accidentally hides a broken initial mount.
    XCTAssertEqual(ember.frame.midX, app.frame.midX, accuracy: 2)

    // Force a real target change as well so the same test covers ongoing
    // scroll ownership and the Inspiration return path.
    none.tap()
    ember.tap()
    let centerBefore = ember.frame.midX
    let compactWidth = ember.frame.width
    XCTAssertEqual(centerBefore, app.frame.midX, accuracy: 2)

    inspiration.tap()
    let back = app.buttons["dash.tray.back"]
    XCTAssertTrue(Self.waitForHittable(back))
    let expandedPanel =
      app.descendants(matching: .any)
      .matching(identifier: "workspace-glow-inspiration-panel-orange")
      .firstMatch
    XCTAssertTrue(expandedPanel.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(expandedPanel.frame.width, compactWidth * 2)
    back.tap()

    XCTAssertTrue(Self.waitForHittable(ember))
    let centerAfter = ember.frame.midX
    XCTAssertEqual(centerAfter, centerBefore, accuracy: 2)
    XCTAssertEqual(centerAfter, app.frame.midX, accuracy: 2)
  }

  func testAvatarOpensSettingsWithProfileAsAChildPage() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    let headerProfile = app.buttons["header-profile-button"]
    XCTAssertTrue(headerProfile.waitForExistence(timeout: 5))
    headerProfile.tap()

    let close = app.buttons["dash.navigation.close"].firstMatch
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    let settingsTitle = app.staticTexts["dash.navigation.title"]
    XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))
    XCTAssertEqual(settingsTitle.label, "Settings")

    let profileRow = app.buttons["settings-profile-row"]
    XCTAssertTrue(profileRow.waitForExistence(timeout: 5))
    profileRow.tap()

    let back = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["User ID"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Registered"].waitForExistence(timeout: 5))

    // The custom container retains this exact Profile host while its child is
    // visible. Returning must restore Profile's live scroll state, not rebuild
    // a fresh screen at the top.
    let auditLog = app.buttons["profile-audit-log-row"]
    for _ in 0..<6 where !auditLog.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(Self.waitForHittable(auditLog))
    auditLog.tap()
    let auditTitle = app.staticTexts["dash.navigation.title"]
    XCTAssertTrue(auditTitle.waitForExistence(timeout: 5))
    XCTAssertEqual(auditTitle.label, "Audit log")

    back.tap()
    XCTAssertTrue(Self.waitForHittable(auditLog))
    back.tap()
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    close.tap()
    XCTAssertTrue(headerProfile.waitForExistence(timeout: 5))
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

    let back = app.buttons["dash.navigation.back"].firstMatch
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

    let tunnelsToggle = app.switches["settings-experimental-tunnels"]
    // The deterministic preview now includes the account-switching row. The
    // lazy stack can therefore expose this element to accessibility before it
    // is on screen; scroll until it is actually tappable, not merely present.
    for _ in 0..<6 where !tunnelsToggle.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(tunnelsToggle.waitForExistence(timeout: 5))
    XCTAssertTrue(Self.waitForHittable(tunnelsToggle))
  }

  /// Registrar has no Resources row: the zone's Registration card is the only
  /// door into a registration, and it only opens for a name this account
  /// registered with Cloudflare.
  func testZoneRegistrationCardOpensRegistrarDetail() {
    let app = XCUIApplication()
    launch(app, arguments: ["-ui-preview"])

    expandHomeDomains(in: app)
    let domainRow = app.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "example.com")
    ).firstMatch
    XCTAssertTrue(domainRow.waitForExistence(timeout: 5))
    domainRow.tap()

    // The card sits below the hero and the zone tools, and its lookup settles a
    // frame after the zone does — so wait for it before scrolling toward it.
    let manage = app.buttons["Manage registration"]
    XCTAssertTrue(manage.waitForExistence(timeout: 5))
    for _ in 0..<6 where !manage.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(Self.waitForHittable(manage))
    manage.tap()

    // "Registration" is the card's title on both screens; Auto-renew exists
    // only on the pushed one, seeded from the cached account index.
    XCTAssertTrue(app.staticTexts["Auto-renew"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))

    let back = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(app.buttons["domain-card-customize"].waitForExistence(timeout: 5))
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
      NSPredicate(
        format: "label == %@",
        "example.com, Email routing, Status, Ready")
    ).firstMatch
    let partialDomain = app.buttons.matching(
      NSPredicate(
        format: "label == %@",
        "docs.example.com, Email routing, Status, Misconfigured")
    ).firstMatch
    let offDomain = app.buttons.matching(
      NSPredicate(
        format: "label BEGINSWITH[c] %@",
        "api.example.net, Email routing")
    ).firstMatch
    XCTAssertTrue(exampleDomain.waitForExistence(timeout: 5))
    XCTAssertTrue(partialDomain.waitForExistence(timeout: 5))
    XCTAssertTrue(offDomain.waitForNonExistence(timeout: 2))
    XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 2))
    exampleDomain.tap()

    XCTAssertTrue(app.staticTexts["Routes"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Destination addresses"].waitForExistence(timeout: 5))
    let actions = app.staticTexts.matching(
      NSPredicate(format: "label == %@", "Actions"))
    XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(actions.count, 1)

    let detailBack = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(detailBack.waitForExistence(timeout: 5))
    detailBack.tap()
    XCTAssertTrue(exampleDomain.waitForExistence(timeout: 5))

    let catalogBack = app.buttons["dash.navigation.back"].firstMatch
    XCTAssertTrue(catalogBack.waitForExistence(timeout: 5))
    catalogBack.tap()
    XCTAssertTrue(app.buttons["Resources"].waitForExistence(timeout: 5))
  }
}
