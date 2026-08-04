import Foundation
import Testing

@testable import CloudflareAPI

// Statuspage summary parsing and the no-auth fetch path. Lives in
// `extension NetworkTests` so `MockURLProtocol` stays serialized with every
// other network test in the target.
extension NetworkTests {
  private static let summaryFixture = Data(
    #"""
    {
      "page": {"id": "yh6f0r4529hb", "updated_at": "2026-08-04T08:28:59.415Z"},
      "status": {"indicator": "minor", "description": "Minor Service Outage"},
      "components": [
        {"id": "1km35smx8p41", "name": "Cloudflare Sites and Services", "status": "operational",
         "group": true,
         "components": ["svc-api", "svc-access"]},
        {"id": "region-group", "name": "Europe", "status": "operational", "group": true,
         "components": ["colo-ams"]},
        {"id": "svc-api", "name": "API", "status": "degraded_performance",
         "group": false, "group_id": "1km35smx8p41"},
        {"id": "svc-access", "name": "Access", "status": "operational",
         "group": false, "group_id": "1km35smx8p41"},
        {"id": "colo-ams", "name": "Amsterdam, Netherlands - (AMS)", "status": "partial_outage",
         "group": false, "group_id": "region-group"}
      ],
      "incidents": [
        {"id": "inc-1", "name": "API errors in some regions", "status": "investigating",
         "impact": "minor",
         "updated_at": "2026-08-04T08:00:00.000Z",
         "incident_updates": [
           {"id": "u2", "body": "We have identified the cause.", "created_at": "2026-08-04T08:00:00.000Z"},
           {"id": "u1", "body": "We are investigating.", "created_at": "2026-08-04T07:00:00.000Z"}
         ]}
      ],
      "scheduled_maintenances": [
        {"id": "mnt-1", "name": "IAD (Ashburn) on 2026-08-04", "status": "scheduled",
         "scheduled_for": "2026-08-04T10:00:00.000Z"},
        {"id": "mnt-2", "name": "LHR (London) on 2026-08-04", "status": "in_progress",
         "scheduled_for": "2026-08-04T07:00:00.000Z"}
      ]
    }
    """#.utf8)

  @Test func statusSummaryParsesIndicatorIncidentsAndServiceComponents() throws {
    let summary = try CloudflareStatusClient.parse(Self.summaryFixture)

    #expect(summary.indicator == .minor)

    // Only the members of the documented services group survive — the colo
    // with a worse status must not leak in through a "show problems" filter.
    #expect(summary.serviceComponents.map(\.id) == ["svc-api", "svc-access"])
    #expect(summary.serviceComponents.first?.status == .degradedPerformance)

    #expect(summary.incidents.count == 1)
    let incident = try #require(summary.incidents.first)
    #expect(incident.status == .investigating)
    // Updates arrive newest-first; the latest body is the first element.
    #expect(incident.latestUpdate == "We have identified the cause.")
    #expect(incident.updatedAt != nil)

    // Scheduled windows are colo noise and are dropped; in-progress survives.
    #expect(summary.activeMaintenances.map(\.id) == ["mnt-2"])
  }

  @Test func statusSummaryMapsUnknownVocabularyWithoutThrowing() throws {
    let data = Data(
      #"""
      {
        "status": {"indicator": "apocalyptic"},
        "components": [
          {"id": "1km35smx8p41", "name": "Cloudflare Sites and Services",
           "group": true, "components": ["svc-new"]},
          {"id": "svc-new", "name": "New Product", "status": "on_fire", "group": false}
        ],
        "incidents": [
          {"id": "inc-x", "name": "Weird incident", "status": "escalated"}
        ],
        "scheduled_maintenances": []
      }
      """#.utf8)

    let summary = try CloudflareStatusClient.parse(data)

    #expect(summary.indicator == .unknown)
    #expect(summary.serviceComponents.first?.status == .unknown)
    #expect(summary.incidents.first?.status == .unknown)
  }

  @Test func statusSummaryDegradesToEmptyServicesWhenGroupIsMissing() throws {
    let data = Data(
      #"""
      {
        "status": {"indicator": "none"},
        "components": [
          {"id": "other-group", "name": "Renamed Group", "group": true,
           "components": ["svc-api"]},
          {"id": "svc-api", "name": "API", "status": "operational", "group": false}
        ]
      }
      """#.utf8)

    let summary = try CloudflareStatusClient.parse(data)

    // A restructured page loses the service list but never invents one — the
    // indicator and incidents stay the headline.
    #expect(summary.indicator == .none)
    #expect(summary.serviceComponents.isEmpty)
    #expect(summary.incidents.isEmpty)
  }

  @Test func statusFetchSendsNoAuthorizationAndThrowsOnHTTPError() async throws {
    let session = mockSession { request in
      #expect(request.url == CloudflareStatusClient.summaryURL)
      // The status page is Atlassian-hosted: a Bearer token here is a leak.
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return (200, Self.summaryFixture)
    }
    let summary = try await CloudflareStatusClient.summary(session: session)
    #expect(summary.indicator == .minor)

    let failing = mockSession { _ in (503, Data()) }
    await #expect(throws: CloudflareStatusClient.FetchError.self) {
      _ = try await CloudflareStatusClient.summary(session: failing)
    }
  }
}
