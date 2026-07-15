import SwiftUI

enum LegalDocument: String, Identifiable {
  case termsOfUse
  case privacyPolicy

  var id: String { rawValue }

  var title: String {
    switch self {
    case .termsOfUse: "Terms of Use"
    case .privacyPolicy: "Privacy Policy"
    }
  }

  var resourceName: String {
    switch self {
    case .termsOfUse: "TermsOfUse"
    case .privacyPolicy: "PrivacyPolicy"
    }
  }

  static func markdown(for document: LegalDocument) -> String {
    let url =
      Bundle.main.url(
        forResource: document.resourceName, withExtension: "md", subdirectory: "Legal")
      ?? Bundle.main.url(forResource: document.resourceName, withExtension: "md")
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
      return "This document is unavailable on this build."
    }
    return text
  }
}

struct LegalDocumentView: View {
  let document: LegalDocument

  private var markdown: AttributedString {
    (try? AttributedString(
      markdown: LegalDocument.markdown(for: document),
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(LegalDocument.markdown(for: document))
  }

  var body: some View {
    ScrollView {
      Text(markdown)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.vertical, DashTheme.Spacing.section)
        .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .background(DashTheme.canvas)
    .navigationTitle(document.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
