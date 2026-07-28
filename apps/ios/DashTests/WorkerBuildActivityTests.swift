import CloudflareAPI
import Foundation
import Testing

@testable import Dash

private func build(_ json: String) throws -> WorkerBuild {
  try JSONDecoder().decode(WorkerBuild.self, from: Data(json.utf8))
}

@Test @MainActor func liveActivityStateCarriesAMachineTokenAndLocalizedCopy() throws {
  let previousLocale = DashL10n.localeOverrideForTesting
  DashL10n.localeOverrideForTesting = Locale(identifier: "en")
  defer { DashL10n.localeOverrideForTesting = previousLocale }

  let running = try build(
    #"""
    {"build_uuid":"b-1","status":"running","running_on":"t",
     "build_trigger_metadata":{"branch":"main","commit_hash":"0123456789abcdef"}}
    """#)
  let state = WorkerBuildActivityControllerBox.contentState(for: running)

  // The widget colours off the token, so it must stay machine-readable even as
  // `phase` is translated. Shipping only a localized string would paint every
  // build the same colour in Chinese.
  #expect(state.phaseToken == "running")
  #expect(state.phase == "Building")
  #expect(state.branch == "main")
  #expect(state.shortCommit == "0123456")
  #expect(state.outcome == nil)
}

@Test func phaseTokensCoverEveryPhaseAndStayDistinct() {
  let phases: [WorkerBuild.Phase] = [.queued, .initializing, .running, .finished]
  let tokens = phases.map(WorkerBuildActivityControllerBox.phaseToken)
  #expect(Set(tokens).count == phases.count)
  // "finished" is the value WidgetColor.workerBuild switches on; renaming it
  // here without renaming it there silently paints finished builds amber.
  #expect(WorkerBuildActivityControllerBox.phaseToken(.finished) == "finished")
}

@Test @MainActor func finishedBuildKeepsItsOutcomeForTheWidgetToColour() throws {
  let failed = try build(#"{"build_uuid":"b","build_outcome":"failure","stopped_on":"t"}"#)
  let state = WorkerBuildActivityControllerBox.contentState(for: failed)
  #expect(state.phaseToken == "finished")
  #expect(state.outcome == "failure")

  let stoppedWithoutOutcome = try build(#"{"build_uuid":"b","stopped_on":"t"}"#)
  // No outcome stays nil rather than defaulting to success — the widget paints
  // that amber ("ended, Cloudflare didn't say how"), not green.
  #expect(WorkerBuildActivityControllerBox.contentState(for: stoppedWithoutOutcome).outcome == nil)
}

@Test func pollBackoffMatchesThePagesLadderAndIsClamped() {
  #expect(WorkerBuildActivityControllerBox.pollDelaySeconds(consecutiveFailures: 0) == 10)
  #expect(WorkerBuildActivityControllerBox.pollDelaySeconds(consecutiveFailures: 3) == 60)
  // Out-of-range input must not trap.
  #expect(WorkerBuildActivityControllerBox.pollDelaySeconds(consecutiveFailures: 99) == 60)
  #expect(WorkerBuildActivityControllerBox.pollDelaySeconds(consecutiveFailures: -1) == 10)
}

@Test func monitorKeyDistinguishesAccountsAndScripts() {
  let a = WorkerBuildMonitorKey(
    accountID: "acc-1", accountGeneration: 0, scriptName: "api", scriptTag: "tag-1")
  let sameScriptOtherAccount = WorkerBuildMonitorKey(
    accountID: "acc-2", accountGeneration: 0, scriptName: "api", scriptTag: "tag-1")
  // Generation is part of identity so a sign-out/sign-in cannot let a stale
  // monitor keep feeding a screen under a fresh session.
  let laterGeneration = WorkerBuildMonitorKey(
    accountID: "acc-1", accountGeneration: 1, scriptName: "api", scriptTag: "tag-1")

  #expect(a != sameScriptOtherAccount)
  #expect(a != laterGeneration)
}
