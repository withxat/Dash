import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Indexes recently opened Cloudflare resources into Spotlight so they open
/// via `dash://` deep links. Cleared on sign-out.
enum DashSpotlight {
  private static let domain = "sh.xat.dash.resources"

  static func index(_ resource: RecentResource) {
    let routeURL: URL?
    switch resource.kind {
    case .zone: routeURL = URL(string: "dash://zone/\(resource.resourceID)")
    case .worker:
      routeURL = URL(
        string:
          "dash://worker/\(resource.resourceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resource.resourceID)"
      )
    case .r2:
      routeURL = URL(
        string:
          "dash://r2/\(resource.resourceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resource.resourceID)"
      )
    case .kv: routeURL = URL(string: "dash://kv/\(resource.resourceID)")
    }
    guard let routeURL else { return }

    let attributes = CSSearchableItemAttributeSet(contentType: .url)
    attributes.title = resource.title
    attributes.contentDescription = "\(resource.kind.displayName) in Dash"
    attributes.keywords = [resource.kind.displayName, "Cloudflare", "Dash", resource.title]
    attributes.url = routeURL
    attributes.displayName = resource.title

    let item = CSSearchableItem(
      uniqueIdentifier: routeURL.absoluteString,
      domainIdentifier: domain,
      attributeSet: attributes
    )
    item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600)
    CSSearchableIndex.default().indexSearchableItems([item], completionHandler: { _ in })
  }

  static func clearAll() {
    CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
  }
}
