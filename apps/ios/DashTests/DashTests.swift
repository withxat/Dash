import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

@Test @MainActor func onboardingWordmarkKeepsLaunchOpticalSpacingAtRest() {
  let magnification = OnboardingBrandTypography.launchMagnification

  for baseSize in [CGFloat(28), 34, 56] {
    let restingFont = OnboardingBrandTypography.wordmarkFont(
      baseSize: baseSize,
      renderMagnification: 1
    )
    let launchFont = OnboardingBrandTypography.wordmarkFont(
      baseSize: baseSize,
      renderMagnification: magnification
    )
    let restingLine = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Dash", attributes: [.font: restingFont])
    )
    let launchLine = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Dash", attributes: [.font: launchFont])
    )

    for characterIndex in 0..<4 {
      let restingOrigin = CTLineGetOffsetForStringIndex(
        restingLine,
        characterIndex,
        nil
      )
      let normalizedLaunchOrigin =
        CTLineGetOffsetForStringIndex(launchLine, characterIndex, nil) / magnification
      #expect(abs(restingOrigin - normalizedLaunchOrigin) < 0.001)
    }

    let restingWidth = CTLineGetTypographicBounds(restingLine, nil, nil, nil)
    let normalizedLaunchWidth =
      CTLineGetTypographicBounds(launchLine, nil, nil, nil) / magnification
    #expect(abs(restingWidth - normalizedLaunchWidth) < 0.001)
  }
}

@Test func configurationRejectsUnexpandedBuildSettings() {
  #expect(
    !AppConfiguration(clientID: "$(DASH_CLIENT_ID)", redirectURI: "$(DASH_REDIRECT_URI)")
      .isConfigured)
}

@Test func buildMetadataUsesASevenCharacterCommitIdentity() {
  #expect(
    DashBuildMetadata.shortCommit(from: "0E4EFE5F473BF3AD2A381F2CFA842AB791318FF4")
      == "0e4efe5")
  #expect(DashBuildMetadata.shortCommit(from: "\nabcdef0123 \n") == "abcdef0")
  #expect(DashBuildMetadata.shortCommit(from: "1234567") == "1234567")
  #expect(DashBuildMetadata.shortCommit(from: "1") == nil)
  #expect(DashBuildMetadata.shortCommit(from: "not-a-sha") == nil)
  #expect(DashBuildMetadata.shortCommit(from: nil) == nil)
}

@Test func hostedAppEmbedsItsBuildCommitIdentity() throws {
  let commit = try #require(DashBuildMetadata.shortCommit(in: .main))
  #expect(commit.count == 7)
  #expect(commit.allSatisfy { $0.isHexDigit })
}

@Test func relayBaseURLStripsPathFromRedirectURI() {
  let configured = AppConfiguration(
    clientID: "client",
    redirectURI: "https://dash.xat.sh/oauth/callback")
  #expect(configured.relayBaseURL?.absoluteString == "https://dash.xat.sh")

  let withPort = AppConfiguration(
    clientID: "client",
    redirectURI: "https://example.test:8443/oauth/callback")
  #expect(withPort.relayBaseURL?.absoluteString == "https://example.test:8443")
}

@Test func relayBaseURLRejectsNonHTTPSAndUnexpanded() {
  #expect(
    AppConfiguration(clientID: "c", redirectURI: "http://dash.xat.sh/oauth/callback")
      .relayBaseURL == nil)
  #expect(
    AppConfiguration(clientID: "c", redirectURI: "$(DASH_REDIRECT_URI)").relayBaseURL == nil)
  #expect(AppConfiguration(clientID: "c", redirectURI: "").relayBaseURL == nil)
  // isConfigured stays independent — an unavailable relay origin must not block sign-in.
  let loginOnly = AppConfiguration(clientID: "client", redirectURI: "http://insecure.test/cb")
  #expect(loginOnly.isConfigured)
  #expect(loginOnly.relayBaseURL == nil)
}

@Test func searchCancellationIsRecognized() {
  #expect(CancellationError().dashIsCancellation)
  #expect(URLError(.cancelled).dashIsCancellation)
  #expect(!URLError(.timedOut).dashIsCancellation)
}
