#if DEBUG
  import CloudflareAPI
  import SwiftUI
  import UIKit

  /// DEBUG-only playground for toast, haptics, and hold-to-confirm. Opened from
  /// Settings — never shipped in Release.
  struct DebugView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DashInteractionPreferences.hapticsKey) private var hapticsEnabled = true
    @State private var holdDemoPhase: DashActionPhase = .idle
    @State private var probeRunning = false
    @State private var probeResult: String?
    @ObservedObject private var holoMotion = HoloMotionManager.shared

    var body: some View {
      ScrollView {
        LazyVStack(spacing: DashTheme.Spacing.section) {
          sessionSection
          holoSection
          webAnalyticsProbeSection
          toastSection
          hapticsSection
          holdSection
          cacheSection
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.vertical, DashTheme.Spacing.section)
      }
      .background(DashTheme.canvas)
      .detailHeader(icon: .solar(SolarAsset.Content.code), title: "Debug")
    }

    // MARK: - Session

    private var sessionSection: some View {
      DashListGroup(title: "Session") {
        dashListCard {
          infoRow(title: "Build", value: "DEBUG")
          DashListGroupDivider()
          infoRow(title: "Demo session", value: model.isDemoSession ? "Yes" : "No")
          DashListGroupDivider()
          infoRow(title: "Account", value: model.activeAccount?.name ?? "—")
          DashListGroupDivider()
          infoRow(title: "Account ID", value: model.activeAccountID ?? "—", mono: true)
          DashListGroupDivider()
          infoRow(title: "Granted scopes", value: "\(model.grantedScopes?.count ?? 0)")
          DashListGroupDivider()
          actionRow(
            title: "Copy access token",
            subtitle: "For curl probes. Expires — copy it again if you get a 401."
          ) {
            Task {
              guard let token = try? await model.tokenStore.getAccessToken(), !token.isEmpty else {
                model.toasts.error("No access token in the Keychain.")
                return
              }
              UIPasteboard.general.string = token
              model.toasts.success("Access token copied.")
            }
          }
        }
      }
    }

    // MARK: - Holo stickers

    private var holoSection: some View {
      DashListGroup(title: "Holo stickers") {
        dashListCard {
          VStack(spacing: 16) {
            HoloStickerView(
              motion: holoMotion,
              shape: RoundedRectangle(cornerRadius: 16, style: .continuous)
            ) {
              Image("LoginAppIcon")
                .resizable()
                .scaledToFit()
            }
            .frame(width: 76, height: 76)
            .dashShadow(
              .raised,
              in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )

            VStack(spacing: 14) {
              holoSlider(
                title: "Gradient sensitivity",
                value: $holoMotion.gradientSensitivity,
                range: 40...320,
                step: 10,
                valueText: "\(Int(holoMotion.gradientSensitivity)) pt/rad"
              )
              holoSlider(
                title: "Sparkle maximum",
                value: $holoMotion.sparkleMaximumOpacity,
                range: 0...0.7,
                step: 0.05,
                valueText: holoMotion.sparkleMaximumOpacity.formatted(
                  .number.precision(.fractionLength(2)))
              )
              holoSlider(
                title: "Reset threshold",
                value: $holoMotion.resetThreshold,
                range: 0.005...0.08,
                step: 0.005,
                valueText: holoMotion.resetThreshold.formatted(
                  .number.precision(.fractionLength(3)))
              )
              holoSlider(
                title: "Update frequency",
                value: $holoMotion.updateFrequency,
                range: 5...30,
                step: 1,
                valueText: "\(Int(holoMotion.updateFrequency)) Hz"
              )
            }

            Button {
              holoMotion.resetReference()
            } label: {
              Text(verbatim: "Reset reference")
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.brand)
                .frame(minHeight: DashTheme.Layout.minimumHitTarget)
            }
            .buttonStyle(DashPressButtonStyle())
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .frame(maxWidth: .infinity)
          .dashListCardInset()
        }
      }
    }

    private func holoSlider(
      title: String,
      value: Binding<Double>,
      range: ClosedRange<Double>,
      step: Double,
      valueText: String
    ) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: title)
            .dashTextStyle(.footnoteSemibold)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 8)
          Text(verbatim: valueText)
            .dashTextStyle(.code)
            .foregroundStyle(DashTheme.subtle)
        }
        Slider(value: value, in: range, step: step)
          .accessibilityLabel(Text(verbatim: title))
          .accessibilityValue(Text(verbatim: valueText))
      }
    }

    // MARK: - Web Analytics probe

    /// Answers two questions the OAuth scope catalog can't: does the token we
    /// already hold read the RUM datasets, and can we list the account's Web
    /// Analytics sites (the only way to map a zone to its siteTag)?
    private var webAnalyticsProbeSection: some View {
      DashListGroup(title: "Web Analytics probe") {
        dashListCard {
          actionRow(
            title: probeRunning ? "Running…" : "Probe RUM access",
            subtitle: "rumPageloadEventsAdaptiveGroups + rum/site_info/list"
          ) {
            guard !probeRunning else { return }
            Task { await runWebAnalyticsProbe() }
          }
          if let probeResult {
            DashListGroupDivider()
            VStack(alignment: .leading, spacing: 8) {
              Text(probeResult)
                .dashTextStyle(.code)
                .foregroundStyle(DashTheme.subtle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .dashListCardInset()
          }
        }
      }
    }

    private func runWebAnalyticsProbe() async {
      guard let accountID = model.activeAccountID else {
        probeResult = "No active account."
        return
      }
      probeRunning = true
      defer { probeRunning = false }

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let until = Date()
      let since = until.addingTimeInterval(-7 * 86400)
      let query = """
        { viewer { accounts(filter: {accountTag: "\(accountID)"}) { \
        rumPageloadEventsAdaptiveGroups(limit: 10, \
        filter: {datetime_geq: "\(formatter.string(from: since))", \
        datetime_leq: "\(formatter.string(from: until))"}) { \
        count dimensions { siteTag } } } } }
        """

      var lines: [String] = []
      do {
        let data = try await model.client.graphQL(query: query)
        lines.append("① GraphQL rumPageloadEventsAdaptiveGroups\n\(preview(data))")
      } catch {
        lines.append("① GraphQL failed\n\(error.dashActionableMessage)")
      }
      do {
        let data = try await model.client.executeRaw(
          path: "/accounts/\(accountID)/rum/site_info/list", method: "GET")
        lines.append("② GET rum/site_info/list\n\(preview(data))")
      } catch {
        lines.append("② GET rum/site_info/list failed\n\(error.dashActionableMessage)")
      }
      probeResult = lines.joined(separator: "\n\n")
    }

    private func preview(_ data: Data) -> String {
      let text = String(decoding: data, as: UTF8.self)
      return text.count > 700 ? String(text.prefix(700)) + "…" : text
    }

    // MARK: - Toasts

    private var toastSection: some View {
      DashListGroup(title: "Toasts") {
        dashListCard {
          actionRow(title: "Success", subtitle: "Deleted successfully.") {
            model.toasts.success(DashL10n.string("Deleted successfully."))
          }
          DashListGroupDivider()
          actionRow(title: "Added / created / saved") {
            model.toasts.success(DashL10n.string("Added successfully."))
            Task {
              try? await Task.sleep(for: .milliseconds(900))
              model.toasts.success(DashL10n.string("Created successfully."))
              try? await Task.sleep(for: .milliseconds(900))
              model.toasts.success(DashL10n.string("Saved successfully."))
            }
          }
          DashListGroupDivider()
          actionRow(title: "Warning", subtitle: "Longer warning copy.") {
            model.toasts.warning(
              "This is a warning toast with a longer message so you can check wrapping and duration."
            )
          }
          DashListGroupDivider()
          actionRow(title: "Error", subtitle: "Actionable failure.") {
            model.toasts.error(
              "Dash couldn’t complete that request. Check the network and try again.")
          }
          DashListGroupDivider()
          actionRow(title: "Rapid replace", subtitle: "Three toasts in a row.") {
            model.toasts.success("First")
            Task {
              try? await Task.sleep(for: .milliseconds(350))
              model.toasts.warning("Second")
              try? await Task.sleep(for: .milliseconds(350))
              model.toasts.error("Third")
            }
          }
          DashListGroupDivider()
          actionRow(title: "Dismiss current") {
            model.toasts.dismiss()
          }
        }
      }
    }

    // MARK: - Haptics

    private var hapticsSection: some View {
      DashListGroup(title: "Haptics") {
        DashToggleRow(
          title: "Haptic feedback",
          subtitle: "Same Settings → General toggle.",
          isOn: $hapticsEnabled
        )
        .onChange(of: hapticsEnabled) { _, enabled in
          if enabled { DashDelight.lightImpact() }
        }

        dashListCard {
          actionRow(title: "Light impact") {
            DashDelight.lightImpact()
          }
          DashListGroupDivider()
          actionRow(title: "Selection changed") {
            DashDelight.selectionChanged()
          }
          DashListGroupDivider()
          actionRow(title: "Warn / medium") {
            DashDelight.warnImpact()
          }
          DashListGroupDivider()
          actionRow(title: "Success notification") {
            DashDelight.celebrateSuccess()
          }
          DashListGroupDivider()
          actionRow(title: "Error notification") {
            DashDelight.failError()
          }
          DashListGroupDivider()
          actionRow(title: "Hold ramp", subtitle: "Soft ticks then medium hit.") {
            Task { await playHoldRamp() }
          }
        }
      }
    }

    // MARK: - Hold to confirm

    private var holdSection: some View {
      DashListGroup(title: "Hold to confirm") {
        dashListCard {
          VStack(alignment: .leading, spacing: 12) {
            DashActionButton(
              title: "Hold to confirm",
              role: .destructive,
              phase: holdDemoPhase,
              holdToConfirm: true,
              onSuccessPresentationCompleted: { holdDemoPhase = .idle }
            ) {
              holdDemoPhase = .loading
              model.toasts.success("Hold confirmed.")
              Task {
                do {
                  try await Task.sleep(for: .milliseconds(600))
                  holdDemoPhase = .succeeded
                } catch {
                  holdDemoPhase = .idle
                }
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .dashListCardInset()
        }
      }
    }

    // MARK: - Cache

    private var cacheSection: some View {
      DashListGroup(title: "Cache") {
        dashListCard {
          actionRow(
            title: "Clear feature cache",
            subtitle: "Drops in-memory listings for this session."
          ) {
            model.featureCache.clear()
            model.toasts.success("Feature cache cleared.")
          }
        }
      }
    }

    // MARK: - Rows

    private func infoRow(title: String, value: String, mono: Bool = false) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
        Spacer(minLength: 8)
        Text(value)
          .dashTextStyle(mono ? .code : .supporting)
          .foregroundStyle(DashTheme.subtle)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .dashListCardInset()
    }

    private func actionRow(
      title: String,
      subtitle: String? = nil,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        DashListRow(
          title: title,
          subtitle: subtitle,
          icon: SolarAsset.Content.bolt,
          showsChevron: false
        )
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .dashListCardInset()
    }

    private func playHoldRamp() async {
      let tickCount = 7
      let tickNanos: UInt64 = 100_000_000
      let ramp = DashDelight.makeHoldRampGenerator()
      for tick in 1..<tickCount {
        let t = CGFloat(tick) / CGFloat(tickCount)
        DashDelight.holdRampImpact(ramp, intensity: 0.18 + 0.72 * (t * t))
        try? await Task.sleep(nanoseconds: tickNanos)
      }
      DashDelight.warnImpact()
    }
  }
#endif
