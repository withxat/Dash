import CloudflareAPI
import SwiftUI

struct FeatureRouterContent: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    let accessLevel = feature.capability.accessLevel(grantedScopes: model.grantedScopes)
    Group {
      if accessLevel != .locked {
        routedContent
          .environment(\.featureAllowsWrites, accessLevel == .full)
          .environment(\.featureRequiredScopes, feature.capability.read)
          .safeAreaInset(edge: .top, spacing: 0) {
            if accessLevel == .readOnly {
              FeatureReadOnlyBanner(feature: feature)
                .padding(.horizontal, DashTheme.Spacing.screen)
                .padding(.bottom, 8)
                .background(DashTheme.canvas)
            }
          }
      } else {
        FeatureAccessRequiredView(feature: feature)
      }
    }
    .detailHeader(icon: .feature(feature), title: feature.title)
  }

  /// Exhaustive on purpose — no `default:`. A new FeatureID must name its screen
  /// here or it does not build.
  @ViewBuilder
  private var routedContent: some View {
    Group {
      switch feature {
      case .zones: ZonesView()
      case .workers: WorkersView()
      case .pages: PagesProjectsView()
      case .r2: R2BucketsView()
      case .kv: KVNamespacesView()
      }
    }
  }
}

struct FeatureReadOnlyBanner: View {
  let feature: FeatureID

  var body: some View {
    FeatureWriteAccessNotice(
      message: "Read-only — grant write access to make changes.",
      scopes: feature.capability.write)
  }
}

/// Shared read-only affordance for a screen whose primary payload can still be
/// inspected without its mutation scope.
struct FeatureWriteAccessNotice: View {
  @Environment(AppModel.self) private var model
  let message: String
  let scopes: Set<String>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DashNotice(kind: .warning, message: message)
      DashAuthorizationDisclosure()
      DashPillButton(
        title: model.isDemoSession ? "Connect your account" : "Grant access",
        isLoading: model.isAuthenticating
      ) {
        model.requestAccess(to: scopes)
      }
    }
  }
}

/// Maps a push destination to the catalog feature that owns its write scopes.
func featureID(for destination: Destination) -> FeatureID? {
  switch destination {
  case .profile, .settings, .about, .openSource, .auditLogs, .pushAlerts, .watchtowerInbox: nil
  #if DEBUG
    case .debug: nil
  #endif
  case .feature(let feature): feature
  case .zone, .dns, .cache, .zoneAnalytics, .zoneWebAnalytics, .zoneWAF, .zoneSettings:
    .zones
  case .worker: .workers
  case .pagesProject, .pagesDeployment, .pagesDomains: .pages
  case .r2Bucket, .r2BucketSettings: .r2
  case .kvNamespace, .kvKey: .kv
  }
}

/// Read scopes a destination needs beyond what its FeatureID declares.
///
/// The literals matter: `dns.*` and `cache.purge` have no FeatureID of their own
/// since DNS Management and Cache & Performance left the catalog, and they are
/// not in `.zones.capability` — putting them there would lock the whole Zones
/// feature for a grant missing one of them. Deleting a case here compiles fine
/// and silently falls through to `.zones.capability.read`, which does not
/// include them. See DashAuthorizationScopes.initialReadOnly.
func readScopes(for destination: Destination) -> Set<String> {
  switch destination {
  case .profile, .settings, .about, .openSource, .watchtowerInbox:
    []
  #if DEBUG
    case .debug:
      []
  #endif
  case .auditLogs:
    ["account-settings.read"]
  case .pushAlerts:
    ["notifications.read"]
  case .dns:
    ["zone.read", "dns.read"]
  case .cache:
    ["zone.read"]
  case .zoneSettings:
    ["zone.read", "zone-settings.read"]
  case .zoneAnalytics:
    DashAuthorizationScopes.zoneAnalytics
  case .zoneWAF:
    DashAuthorizationScopes.zoneAnalytics.union(["zone-settings.read"])
  case .zoneWebAnalytics:
    DashAuthorizationScopes.webAnalytics
  case .feature, .zone, .worker, .pagesProject, .pagesDeployment, .pagesDomains, .r2Bucket,
    .r2BucketSettings, .kvNamespace, .kvKey:
    featureID(for: destination)?.capability.read ?? []
  }
}

/// Mutation scopes stay separate so Demo and per-control UI gating can render a
/// destination without enabling write controls owned by a sibling screen.
func writeScopes(for destination: Destination) -> Set<String> {
  switch destination {
  case .settings, .about, .openSource, .auditLogs, .watchtowerInbox, .zoneAnalytics,
    .zoneWebAnalytics:
    []
  #if DEBUG
    case .debug:
      []
  #endif
  case .pushAlerts:
    ["notifications.write"]
  case .profile:
    ["account-settings.write"]
  case .dns:
    ["dns.write"]
  case .cache:
    ["cache.purge"]
  case .zoneSettings:
    ["zone-settings.write"]
  case .zoneWAF:
    ["zone-settings.write"]
  case .feature, .zone, .worker, .pagesProject, .pagesDeployment, .pagesDomains, .r2Bucket,
    .r2BucketSettings, .kvNamespace, .kvKey:
    featureID(for: destination)?.capability.write ?? []
  }
}

func requiredScopes(for destination: Destination) -> Set<String> {
  readScopes(for: destination).union(writeScopes(for: destination))
}

private struct FeatureWriteAccessKey: EnvironmentKey {
  /// A feature screen rendered outside `DestinationRoutedContent` must never
  /// inherit mutation access accidentally.
  static let defaultValue = false
}

private struct FeatureRequiredScopesKey: EnvironmentKey {
  static let defaultValue: Set<String> = []
}

private struct FeatureIdentityKey: EnvironmentKey {
  static let defaultValue: FeatureID? = nil
}

extension EnvironmentValues {
  var featureAllowsWrites: Bool {
    get { self[FeatureWriteAccessKey.self] }
    set { self[FeatureWriteAccessKey.self] = newValue }
  }

  var featureRequiredScopes: Set<String> {
    get { self[FeatureRequiredScopesKey.self] }
    set { self[FeatureRequiredScopesKey.self] = newValue }
  }

  /// Catalog feature that owns the current workspace destination, when any.
  /// List icons and chrome read this so a feature keeps one accent color.
  var featureIdentity: FeatureID? {
    get { self[FeatureIdentityKey.self] }
    set { self[FeatureIdentityKey.self] = newValue }
  }
}

private struct FeatureAccessRequiredView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  var body: some View {
    ScrollView {
      DashCard {
        VStack(alignment: .leading, spacing: DashTheme.Spacing.comfortable) {
          SolarIcon(
            asset: SolarAsset.Content.lock, size: 30,
            color: FeatureVisualIdentity.heroColor(for: feature))
          Text("Cloudflare access")
            .dashTextStyle(.sectionTitle)
            .foregroundStyle(DashTheme.strong)
          Text(
            "This module needs \(feature.capability.read.sorted().joined(separator: ", ")). You can review the request before Cloudflare opens."
          )
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          Text(
            "Dash requests all permissions used by its current features in one authorization."
          )
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          DashPillButton(
            title: "Grant access",
            isLoading: model.isAuthenticating
          ) {
            model.requestAccess(to: feature.capability.read)
          }
        }
      }
      .padding(DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
  }
}
