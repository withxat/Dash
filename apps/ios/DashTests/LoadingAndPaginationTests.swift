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

@Test func coldFailureWashRampClearsAtTopAndFillsTowardTheCenteredCopy() {
  let stops = DashColdFailureWashRamp.stops
  // Clear at the top of the veil so the skeleton peeks through; densest from
  // mid to bottom so the centred tip sits on readable canvas.
  #expect(stops.first?.location == 0)
  #expect(stops.first?.opacity == 0)
  #expect(stops.last?.location == 1)
  #expect(stops.last?.opacity == 0.88)
  // Monotonic: locations climb top → bottom and opacity only rises, so the
  // wash never re-thins under the copy.
  for (previous, next) in zip(stops, stops.dropFirst()) {
    #expect(next.location > previous.location)
    #expect(next.opacity >= previous.opacity)
  }
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
    received: 50, loaded: 50, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(state.totalCount == 120)
  #expect(state.canLoadMore)

  // Final page: loaded reaches total.
  state.absorb(
    info: ResultInfo(page: 3, perPage: 50, totalCount: 120, cursor: nil),
    received: 20, loaded: 120, pageSize: 50)
  #expect(state.nextPage == 4)
  #expect(!state.canLoadMore)

  // Heuristic without result_info: a full page may have a successor.
  state.reset()
  state.absorb(info: nil, received: 50, loaded: 50, pageSize: 50)
  #expect(state.nextPage == 2)
  #expect(state.canLoadMore)
  state.absorb(info: nil, received: 12, loaded: 62, pageSize: 50)
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
    model.featureCache.set(FeatureCacheKey.zones(context.accountID), cached)

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
