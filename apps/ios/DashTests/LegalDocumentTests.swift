import CloudflareAPI
import CoreText
import SwiftUI
import Testing
import UIKit

@testable import Dash

extension LocalizationTests {
  @Test func legalDocumentsExposeStableTitles() {
    let previousLocale = DashL10n.localeOverrideForTesting
    DashL10n.localeOverrideForTesting = Locale(identifier: "en")
    defer { DashL10n.localeOverrideForTesting = previousLocale }

    #expect(LegalDocument.termsOfUse.title == "Terms of Use")
    #expect(LegalDocument.privacyPolicy.title == "Privacy Policy")
    #expect(LegalDocument.termsOfUse.resourceName == "TermsOfUse")
    #expect(LegalDocument.privacyPolicy.resourceName == "PrivacyPolicy")
  }
}

// MARK: - Legal document Markdown

@Test func legalDocumentParserClassifiesEveryBlockKind() {
  let blocks = LegalBlock.blocks(
    from: """
      # Terms of Use

      Effective July 16, 2026.

      ## 1. What Dash is

      - OAuth tokens stay in the Keychain.
      - Account data travels straight to Cloudflare.
      """)

  #expect(blocks.map(\.kind) == [.title, .paragraph, .section, .bullet, .bullet])
  #expect(String(blocks[0].text.characters) == "Terms of Use")
  // Inline-only parsing, so a numbered heading keeps its literal "1." prefix
  // instead of becoming an ordered list.
  #expect(String(blocks[2].text.characters) == "1. What Dash is")
}

@Test func legalDocumentParserJoinsHardWrappedLines() {
  let blocks = LegalBlock.blocks(
    from: """
      Dash signs in to Cloudflare with OAuth using exactly the permission scopes
      you approve.

      - Operation files are removed when the operation completes, fails, or is
        cancelled.
      """)

  #expect(blocks.count == 2)
  #expect(
    String(blocks[0].text.characters)
      == "Dash signs in to Cloudflare with OAuth using exactly the permission scopes you approve.")
  #expect(
    String(blocks[1].text.characters)
      == "Operation files are removed when the operation completes, fails, or is cancelled.")
}

@Test func legalDocumentParserStylesInlineSyntax() throws {
  let blocks = LegalBlock.blocks(
    from: "Stored at `api.cloudflare.com` under **your** [policy](https://example.com/p).")
  let text = try #require(blocks.first?.text)
  #expect(String(text.characters) == "Stored at api.cloudflare.com under your policy.")

  let code = try #require(
    text.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
  #expect(String(text[code.range].characters) == "api.cloudflare.com")
  // A run background is the only way to tint inline code inside one `Text`.
  #expect(code.backgroundColor == DashTheme.recessed)

  let strong = try #require(
    text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
  #expect(String(text[strong.range].characters) == "your")
  #expect(strong.foregroundColor == DashTheme.strong)

  let link = try #require(text.runs.first { $0.link != nil })
  #expect(link.link == URL(string: "https://example.com/p"))
  #expect(link.foregroundColor == DashTheme.brand)
}

@Test func legalDocumentParserKeepsUnsupportedSyntaxAsText() {
  // Dash renders six constructs. Anything else must survive as readable text
  // rather than vanish from a document that has legal effect.
  let blocks = LegalBlock.blocks(
    from: """
      > A blockquote these documents never use.

      | a | b |
      """)

  #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
  #expect(String(blocks[0].text.characters) == "> A blockquote these documents never use.")
  #expect(String(blocks[1].text.characters) == "| a | b |")
}

@Test func legalDocumentBlockIDsIndexTheirOwnArray() {
  let blocks = LegalBlock.blocks(
    from: """
      # Title

      One.

      ## Section

      - Item
      - Item

      Two.
      """)

  // `LegalDocumentView` finds a block's predecessor with `blocks[block.id - 1]`,
  // so the id has to stay the array index.
  #expect(blocks.map(\.id) == Array(blocks.indices))
}

@Test func legalDocumentSpacingOpensSectionsAndTightensBullets() {
  #expect(LegalBlockKind.title.spacing(after: nil) == 0)
  #expect(LegalBlockKind.section.spacing(after: .paragraph) == DashTheme.Spacing.section)
  #expect(LegalBlockKind.section.spacing(after: .title) == DashTheme.Spacing.section)
  #expect(LegalBlockKind.paragraph.spacing(after: .title) == DashTheme.Spacing.itemGap)
  #expect(LegalBlockKind.paragraph.spacing(after: .section) == DashTheme.Spacing.compact)
  #expect(LegalBlockKind.bullet.spacing(after: .bullet) == DashTheme.Spacing.rowInset)
  #expect(LegalBlockKind.paragraph.spacing(after: .paragraph) == DashTheme.Spacing.comfortable)
}

@Test func legalDocumentsShippedInTheBundleParseIntoStructuredBlocks() throws {
  for document in [LegalDocument.termsOfUse, .privacyPolicy] {
    let source = LegalDocument.markdown(for: document)
    try #require(source.contains("# Dash for Cloudflare"), "\(document.rawValue) is missing")

    let blocks = LegalBlock.blocks(from: source)
    #expect(blocks.map(\.kind).contains(.title))
    #expect(blocks.filter { $0.kind == .section }.count >= 5)
    #expect(blocks.allSatisfy { !$0.text.characters.isEmpty })
  }
}

@Test func legalDocumentsStayInsideTheSyntaxDashCanRender() {
  // The in-app documents are symlinks into `packages/legal`, and the same files
  // are rendered on the web by react-markdown, which handles far more syntax
  // than this screen. A table added there would still render on the web and
  // degrade to literal text in the app, so the contract is enforced here rather
  // than left to whoever reviews the wording.
  let unsupportedPrefixes = [
    "> ",  // blockquote
    "|",  // table row
    "```",  // fenced code block
    "![",  // image
    "### ",  // heading past h2
    "* ",  // a bullet this parser does not accept — the documents use "- "
    "+ ",
  ]

  for document in [LegalDocument.termsOfUse, .privacyPolicy] {
    let lines = LegalDocument.markdown(for: document).components(separatedBy: .newlines)
    for (offset, rawLine) in lines.enumerated() {
      let position = "\(document.rawValue):\(offset + 1)"
      let line = rawLine.trimmingCharacters(in: .whitespaces)

      for prefix in unsupportedPrefixes {
        #expect(
          !line.hasPrefix(prefix), "\(position) uses \(prefix), which this screen cannot lay out")
      }
      #expect(
        line.range(of: "^[0-9]+\\. ", options: .regularExpression) == nil,
        "\(position) starts an ordered list, which this screen flattens into a paragraph")
      #expect(
        !(rawLine.hasPrefix("  ") && line.hasPrefix("- ")),
        "\(position) nests a list, which this screen flattens into one level")
    }
  }
}
