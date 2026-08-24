import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test func listPhaseKeepsContentVisibleThroughRefreshFailures() {
  #expect(
    DashListPhase.resolve(isLoading: true, error: nil, hasContent: false) == .loading)
  #expect(
    DashListPhase.resolve(isLoading: true, error: "boom", hasContent: true)
      == .content(banner: "boom", refreshing: true))
  #expect(
    DashListPhase.resolve(isLoading: false, error: "boom", hasContent: false)
      == .fullScreenError("boom"))
  #expect(
    DashListPhase.resolve(isLoading: false, error: "boom", hasContent: true)
      == .content(banner: "boom", refreshing: false))
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: true)
      == .content(banner: nil, refreshing: false))
  // Settled-empty keeps the placeholder body mounted. Snapshot screens (chart
  // detail) and details whose chrome is not tied to primary rows (R2 bucket
  // settings) must set hasContent after settle —
  // leaving the default false is a permanent skeleton, not a calm empty.
  #expect(
    DashListPhase.resolve(isLoading: false, error: nil, hasContent: false)
      == .empty)
  #expect(
    DashListPhase.resolve(isLoading: true, error: nil, hasContent: true)
      == .content(banner: nil, refreshing: true))
}

@Test func listPhaseBodyModeStaysLiveAcrossWarmRefresh() {
  #expect(DashListPhase.loading.bodyMode == .placeholder)
  #expect(DashListPhase.empty.bodyMode == .placeholder)
  #expect(DashListPhase.fullScreenError("boom").bodyMode == .placeholder)
  #expect(
    DashListPhase.content(banner: nil, refreshing: false).bodyMode == .live)
  // Warm refresh keeps `.live` so the handoff animation does not replay.
  #expect(
    DashListPhase.content(banner: nil, refreshing: true).bodyMode == .live)
  #expect(
    DashListPhase.content(banner: "boom", refreshing: true).bodyMode == .live)
}

@Test func bodyHandoffAnimatesOnlyColdToLiveAfterTheFirstFrame() {
  #expect(
    DashBodyHandoffRules.update(displayed: nil, target: .placeholder)
      == DashBodyHandoffUpdate(mode: .placeholder, animates: false))
  #expect(
    DashBodyHandoffRules.update(displayed: nil, target: .live)
      == DashBodyHandoffUpdate(mode: .live, animates: false))
  #expect(
    DashBodyHandoffRules.update(displayed: .placeholder, target: .live)
      == DashBodyHandoffUpdate(mode: .live, animates: true))
  #expect(
    DashBodyHandoffRules.update(
      displayed: .placeholder,
      target: .live,
      reduceMotion: true
    ) == DashBodyHandoffUpdate(mode: .live, animates: false))
  #expect(
    DashBodyHandoffRules.update(displayed: .live, target: .placeholder)
      == DashBodyHandoffUpdate(mode: .placeholder, animates: false))
  #expect(DashBodyHandoffRules.update(displayed: .live, target: .live) == nil)
  #expect(
    DashBodyHandoffRules.update(displayed: .placeholder, target: .placeholder) == nil)
}

@Test func bodyHandoffRecedesOnlySurplusPlaceholderRows() {
  #expect(!DashBodyListSlotRules.placeholderRecedes(index: 0, liveItemCount: 2))
  #expect(!DashBodyListSlotRules.placeholderRecedes(index: 1, liveItemCount: 2))
  #expect(DashBodyListSlotRules.placeholderRecedes(index: 2, liveItemCount: 2))
  #expect(DashBodyListSlotRules.placeholderRecedes(index: 0, liveItemCount: 0))
  #expect(!DashBodyListSlotRules.placeholderRecedes(index: 3, liveItemCount: 4))
}

@Test func coldOverlayIntentAppearsOnlyAfterColdPhaseSettles() {
  let retrying = DashListPhase.resolve(
    isLoading: true,
    error: "old failure",
    hasContent: false)
  #expect(retrying == .loading)
  #expect(DashColdOverlayRules.intent(phase: retrying, hasEmptyCopy: true) == nil)
  #expect(
    DashColdOverlayRules.intent(
      phase: .fullScreenError("boom"),
      hasEmptyCopy: true
    ) == .failure("boom"))
  #expect(
    DashColdOverlayRules.intent(phase: .empty, hasEmptyCopy: true) == .empty)
  #expect(
    DashColdOverlayRules.intent(phase: .empty, hasEmptyCopy: false) == nil)
  #expect(
    DashColdOverlayRules.intent(
      phase: .content(banner: "warm failure", refreshing: false),
      hasEmptyCopy: true
    ) == nil)
}

@Test func coldOverlayUsesOnboardingItemStagger() {
  #expect(DashItemStaggerMotion.lift == 18)
  #expect(DashItemStaggerMotion.interval == 0.055)
  #expect(DashItemStaggerMotion.entranceDuration == 0.3)
  #expect(DashItemStaggerMotion.exitDuration == 0.2)

  let hidden = DashItemStaggerMotion.plan(
    visible: false,
    index: 2,
    reduceMotion: false)
  #expect(hidden.opacity == 0)
  #expect(hidden.offsetY == 18)
  #expect(hidden.delay == 0.11)

  let shown = DashItemStaggerMotion.plan(
    visible: true,
    index: 2,
    reduceMotion: false)
  #expect(shown.opacity == 1)
  #expect(shown.offsetY == 0)
  #expect(shown.delay == 0.11)

  let reduced = DashItemStaggerMotion.plan(
    visible: false,
    index: 3,
    reduceMotion: true)
  #expect(reduced.opacity == 0)
  #expect(reduced.offsetY == 0)
  #expect(reduced.delay == 0)
}

@Test func translucentNoticeWashDenselyVeilsEverythingBelowTwoSkeletonRows() {
  #expect(
    DashTranslucentNoticeWashRamp.fadeDepth
      == DashTheme.Layout.subtitledListRow * 2)
  #expect(DashTranslucentNoticeWashRamp.peakOpacity >= 0.95)

  for height: CGFloat in [420, 800] {
    let stops = DashTranslucentNoticeWashRamp.stops(for: height)
    // The gradient is expressed bottom → top: dense beneath the copy, clear
    // at the top where roughly two placeholder seats remain visible.
    #expect(stops.first?.location == 0)
    #expect(stops.first?.opacity == DashTranslucentNoticeWashRamp.peakOpacity)
    #expect(stops.last?.location == 1)
    #expect(stops.last?.opacity == 0)
    let measuredFadeDepth = (1 - stops[1].location) * height
    #expect(
      abs(measuredFadeDepth - DashTranslucentNoticeWashRamp.fadeDepth) < 0.001)
    #expect(stops[1].opacity == DashTranslucentNoticeWashRamp.peakOpacity)

    for (previous, next) in zip(stops, stops.dropFirst()) {
      #expect(next.location > previous.location)
      #expect(next.opacity <= previous.opacity)
    }
  }

  let compactStops = DashTranslucentNoticeWashRamp.stops(for: 100)
  #expect(compactStops.count == 5)
  #expect(compactStops.first?.location == 0)
  #expect(compactStops.first?.opacity == DashTranslucentNoticeWashRamp.peakOpacity)
  #expect(compactStops.last?.location == 1)
  #expect(compactStops.last?.opacity == 0)
  for (previous, next) in zip(compactStops, compactStops.dropFirst()) {
    #expect(next.location > previous.location)
    #expect(next.opacity <= previous.opacity)
  }
}

@Test func translucentNoticeWashPhysicallyDropsBlurForReducedTransparency() {
  #expect(
    DashTranslucentNoticeWashLayerRules.mountsBackdropMaterial(
      reduceTransparency: false))
  #expect(
    !DashTranslucentNoticeWashLayerRules.mountsBackdropMaterial(
      reduceTransparency: true))
}

@Test func failurePresentationMapsRecoveryActions() {
  #expect(
    DashFailurePresentation.from(
      message: "Your Cloudflare session is no longer valid. Sign in again."
    )
    .action == .signInAgain)
  #expect(
    DashFailurePresentation.from(message: "Permission denied\n\nGrant access for this product.")
      .action == .grantAccess)
  #expect(DashFailurePresentation.from(message: "offline").action == .tryAgain)
  #expect(DashFailureAction.signInAgain.title == "Sign in again")
  #expect(DashFailureAction.grantAccess.title == "Grant access")
  #expect(
    DashFailurePresentation.from(
      error: CloudflareAPIError.request(status: 404, errors: [])
    ).message
      == "Cloudflare couldn’t find this resource. It may have been removed or belong to another account."
  )
  #expect(
    DashFailurePresentation.from(error: CloudflareAPIError.transport("timed out")).message
      == "Dash couldn’t reach Cloudflare. Check your connection and try again."
  )
  #expect(
    DashFailurePresentation.from(
      error: CloudflareAPIError.request(
        status: 400,
        errors: [APIErrorItem(code: 81053, message: "Record already exists.")]
      )
    ).message == "Record already exists."
  )
  #expect(
    DashFailurePresentation.from(
      error: CloudflareAPIError.request(status: 422, errors: [])
    ).message
      == "Cloudflare couldn’t process this request. Check the resource and try again."
  )
  #expect(
    CloudflareAPIError.request(
      status: 400,
      errors: [APIErrorItem(code: 81053, message: "Record already exists.")]
    ).dashActionableMessage == "Record already exists."
  )
}

@Test func pageStateAdvancesAndStopsOnTotals() {
  var state = DashPageState()
  #expect(state.nextPage == 1)
  #expect(!state.canLoadMore)

  // Total-driven: 50 of 120 loaded → more remain, request page 2 next.
  state.absorb(
    info: ResultInfo(page: 1, perPage: 50, totalCount: 120, cursor: nil),
    requestedPage: 1, received: 50, added: 50, loaded: 50, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(state.totalCount == 120)
  #expect(state.canLoadMore)

  // Final page: loaded reaches total.
  state.absorb(
    info: ResultInfo(page: 3, perPage: 50, totalCount: 120, cursor: nil),
    requestedPage: 3, received: 20, added: 20, loaded: 120, pageSize: 50)
  #expect(state.nextPage == 4)
  #expect(!state.canLoadMore)

  // Heuristic without result_info: a full page may have a successor.
  state.reset()
  state.absorb(
    info: nil, requestedPage: 1, received: 50, added: 50, loaded: 50,
    pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(state.canLoadMore)
  state.absorb(
    info: nil, requestedPage: 2, received: 12, added: 12, loaded: 62,
    pageSize: 50)
  #expect(!state.canLoadMore)
}

@Test func pageStateIgnoresStalePageMetadataAndStopsOnRepeatedIdentities() {
  var state = DashPageState()
  state.absorb(
    info: ResultInfo(page: 1, perPage: 50, totalCount: nil, cursor: nil),
    requestedPage: 4, received: 50, added: 50, loaded: 200, pageSize: 50)
  #expect(state.nextPage == 5)
  #expect(state.canLoadMore)

  state.absorb(
    info: ResultInfo(page: 1, perPage: 50, totalCount: nil, cursor: nil),
    requestedPage: 5, received: 50, added: 0, loaded: 200, pageSize: 50)
  #expect(state.nextPage == 6)
  #expect(!state.canLoadMore)
}

@Test func pageStateRehydratesFromCachedArrays() {
  var state = DashPageState()
  state.rehydrate(loaded: 100, pageSize: 50)
  #expect(state.nextPage == 3)
  #expect(state.canLoadMore)

  state.rehydrate(loaded: 62, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(!state.canLoadMore)

  state.rehydrate(loaded: 0, pageSize: 50)
  #expect(state.nextPage == 1)
  #expect(!state.canLoadMore)
}

@Test func zonesCatalogEagerFetchStopsAtBudgetOrWhenComplete() {
  #expect(ZonesCatalogFetchRules.pageSize == 50)
  #expect(ZonesCatalogFetchRules.eagerPageBudget == 40)
  #expect(
    ZonesCatalogFetchRules.shouldContinueEagerly(pagesFetched: 1, canLoadMore: true))
  #expect(
    ZonesCatalogFetchRules.shouldContinueEagerly(
      pagesFetched: ZonesCatalogFetchRules.eagerPageBudget - 1,
      canLoadMore: true))
  #expect(
    !ZonesCatalogFetchRules.shouldContinueEagerly(
      pagesFetched: ZonesCatalogFetchRules.eagerPageBudget,
      canLoadMore: true))
  #expect(
    !ZonesCatalogFetchRules.shouldContinueEagerly(pagesFetched: 3, canLoadMore: false))
}

@Test func zonePickerSubmissionEffectsStayBoundToTheLoadedAccountGeneration() throws {
  let loaded = AccountRequestContext(accountID: "account-a", generation: 4)
  let switched = AccountRequestContext(accountID: "account-b", generation: 5)
  let regenerated = AccountRequestContext(accountID: "account-a", generation: 6)

  let submission = try #require(
    DashZonePickerSubmissionGuard.submissionContext(
      zonesContext: loaded,
      currentContext: loaded))
  #expect(submission == loaded)
  #expect(
    DashZonePickerSubmissionGuard.submissionContext(
      zonesContext: loaded,
      currentContext: switched) == nil)
  #expect(
    DashZonePickerSubmissionGuard.submissionContext(
      zonesContext: loaded,
      currentContext: regenerated) == nil)

  #expect(
    DashZonePickerSubmissionGuard.allowsEffects(
      for: submission,
      zonesContext: loaded,
      currentContext: loaded,
      isCancelled: false))
  #expect(
    !DashZonePickerSubmissionGuard.allowsEffects(
      for: submission,
      zonesContext: switched,
      currentContext: loaded,
      isCancelled: false))
  #expect(
    !DashZonePickerSubmissionGuard.allowsEffects(
      for: submission,
      zonesContext: loaded,
      currentContext: switched,
      isCancelled: false))
  #expect(
    !DashZonePickerSubmissionGuard.allowsEffects(
      for: submission,
      zonesContext: loaded,
      currentContext: loaded,
      isCancelled: true))
}

@Suite(.serialized)
struct DashZonePickerLoaderTests {
  @Test @MainActor
  func cachedEmptyZonesLoadAsSettledEmptyWithoutRequesting() async throws {
    let recorder = DashZonePickerRequestRecorder()
    let session = dashZonePickerSession { request in
      recorder.record(request)
      return (500, Data())
    }
    defer { DashZonePickerURLProtocol.handler = nil }
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: ""),
      tokenStore: DemoTokenStore(),
      session: session,
      deferredDeletionPersistence: nil)
    model.activeAccountID = "cached-empty-account"
    let context = try #require(model.accountRequestContext)
    let cached: [CloudflareZone] = []
    model.featureCache.storeZones(
      cached,
      accountID: context.accountID,
      catalogIsComplete: true)

    let result = await DashZonePickerLoader.load(model: model, context: context)

    #expect(result == .loaded([]))
    #expect(recorder.requests.isEmpty)
  }

  @Test @MainActor
  func zoneRequestFailureLoadsAsFailedInsteadOfEmpty() async throws {
    let recorder = DashZonePickerRequestRecorder()
    let session = dashZonePickerSession { request in
      recorder.record(request)
      return (
        503,
        Data(
          #"{"success":false,"errors":[{"code":1000,"message":"temporary failure"}],"messages":[],"result":null}"#
            .utf8)
      )
    }
    defer { DashZonePickerURLProtocol.handler = nil }
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: ""),
      tokenStore: DemoTokenStore(),
      session: session,
      deferredDeletionPersistence: nil)
    model.activeAccountID = "failed-request-account"
    let context = try #require(model.accountRequestContext)

    let result = await DashZonePickerLoader.load(model: model, context: context)

    guard case .failed(let message) = result else {
      Issue.record("Expected a failed zone-picker result, got \(result)")
      return
    }
    #expect(!message.isEmpty)
    let requests = recorder.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.path.hasSuffix("/zones"))
    #expect(request.query["account.id"] == context.accountID)
    #expect(request.query["per_page"] == String(ZonesView.pageSize))
  }

  @Test @MainActor
  func partialZonesCacheIsRefetchedBeforePickerSettles() async throws {
    let recorder = DashZonePickerRequestRecorder()
    let session = dashZonePickerSession { request in
      recorder.record(request)
      return (
        200,
        Data(
          #"{"success":true,"errors":[],"messages":[],"result":[{"id":"remote-zone","name":"remote.example","status":"active"}],"result_info":{"page":1,"per_page":50,"count":1,"total_count":1}}"#
            .utf8)
      )
    }
    defer { DashZonePickerURLProtocol.handler = nil }
    let model = AppModel(
      configuration: AppConfiguration(clientID: "test", redirectURI: ""),
      tokenStore: DemoTokenStore(),
      session: session,
      deferredDeletionPersistence: nil)
    model.activeAccountID = "partial-cache-account"
    let context = try #require(model.accountRequestContext)
    let partial = try JSONDecoder().decode(
      [CloudflareZone].self,
      from: Data(
        #"[{"id":"cached-zone","name":"cached.example","status":"active"}]"#.utf8))
    model.featureCache.storeZones(
      partial,
      accountID: context.accountID,
      catalogIsComplete: false)

    let result = await DashZonePickerLoader.load(model: model, context: context)

    guard case .loaded(let zones) = result else {
      Issue.record("Expected the picker to replace its partial cache, got \(result)")
      return
    }
    #expect(zones.map(\.id) == ["remote-zone"])
    #expect(recorder.requests.count == 1)
    #expect(model.featureCache.zonesCatalogIsComplete(accountID: context.accountID))
  }
}

private struct DashZonePickerRecordedRequest: Sendable {
  let path: String
  let query: [String: String]
}

private final class DashZonePickerRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [DashZonePickerRecordedRequest] = []

  var requests: [DashZonePickerRecordedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(_ request: URLRequest) {
    let components = request.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)
    }
    let query = Dictionary(
      uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      })
    lock.lock()
    recorded.append(
      DashZonePickerRecordedRequest(path: components?.path ?? "", query: query))
    lock.unlock()
  }
}

private final class DashZonePickerURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func dashZonePickerSession(
  handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
) -> URLSession {
  DashZonePickerURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [DashZonePickerURLProtocol.self]
  return URLSession(configuration: configuration)
}
