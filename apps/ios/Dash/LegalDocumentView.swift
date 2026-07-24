import MarkdownUI
import SwiftUI

enum LegalDocument: String, Identifiable {
  case termsOfUse
  case privacyPolicy

  var id: String { rawValue }

  var title: String {
    switch self {
    case .termsOfUse: DashL10n.ui("Terms of Use")
    case .privacyPolicy: DashL10n.ui("Privacy Policy")
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
      return DashL10n.string("This document is unavailable on this build.")
    }
    return text
  }
}

struct LegalDocumentView: View {
  let document: LegalDocument

  var body: some View {
    ScrollView {
      Markdown(LegalDocument.markdown(for: document))
        .markdownTheme(.dashLegal)
        .dashTextStyle(.supporting)
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

extension Theme {
  @MainActor
  fileprivate static let dashLegal = Theme.basic
    .text {
      ForegroundColor(DashTheme.text)
    }
    .strong {
      FontWeight(.semibold)
      ForegroundColor(DashTheme.strong)
    }
    .link {
      ForegroundColor(DashTheme.brand)
    }
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.9))
      BackgroundColor(DashTheme.recessed)
    }
    .heading1 { configuration in
      configuration.label
        .fixedSize(horizontal: false, vertical: true)
        .markdownMargin(top: .zero, bottom: .em(0.8))
        .markdownTextStyle {
          FontWeight(.bold)
          FontSize(.em(1.55))
          ForegroundColor(DashTheme.strong)
        }
    }
    .heading2 { configuration in
      configuration.label
        .fixedSize(horizontal: false, vertical: true)
        .markdownMargin(top: .em(1.25), bottom: .em(0.55))
        .markdownTextStyle {
          FontWeight(.semibold)
          FontSize(.em(1.15))
          ForegroundColor(DashTheme.strong)
        }
    }
    .paragraph { configuration in
      configuration.label
        .fixedSize(horizontal: false, vertical: true)
        .relativeLineSpacing(.em(0.22))
        .markdownMargin(top: .zero, bottom: .em(0.9))
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: .em(0.2))
    }
}
