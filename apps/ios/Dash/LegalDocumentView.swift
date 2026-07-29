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

/// What a legal document line turned into.
enum LegalBlockKind {
  case title
  case section
  case paragraph
  case bullet

  /// iOS text styles rather than fixed point sizes, so Dynamic Type scales the
  /// document without a `ScaledMetric` per block. `.subheadline` is 15pt — the
  /// same base as `DashTextStyle.supporting`, which this screen used to set on
  /// the document as a whole.
  var textStyle: Font.TextStyle {
    switch self {
    case .title: .title2
    case .section: .headline
    case .paragraph, .bullet: .subheadline
    }
  }

  /// Inline runs need a `Font` value rather than a view modifier, so block
  /// fonts speak the same vocabulary instead of mixing in `dashTextStyle`.
  var font: Font {
    switch self {
    // `.headline` already carries semibold and `.subheadline` regular.
    case .title: .system(.title2, weight: .bold)
    case .section, .paragraph, .bullet: .system(textStyle)
    }
  }

  /// Headings are already heavy, so `**strong**` inside one takes only the
  /// emphasis ink — re-weighting it would render it lighter than its heading.
  var emphasizedFont: Font? {
    switch self {
    case .title, .section: nil
    case .paragraph, .bullet: font.weight(.semibold)
    }
  }

  var color: Color {
    switch self {
    case .title, .section: DashTheme.strong
    case .paragraph, .bullet: DashTheme.text
    }
  }

  /// Air above this block. Semantic spacing on `DashTheme` tokens rather than a
  /// port of the old em-based Markdown margins: a heading opens a group,
  /// consecutive bullets keep a tight rhythm, everything else takes the
  /// paragraph gap.
  func spacing(after previous: LegalBlockKind?) -> CGFloat {
    guard let previous else { return 0 }
    return switch (previous, self) {
    case (_, .section): DashTheme.Spacing.section
    case (.title, _): DashTheme.Spacing.itemGap
    case (.section, _): DashTheme.Spacing.compact
    case (.bullet, .bullet): DashTheme.Spacing.rowInset
    default: DashTheme.Spacing.comfortable
    }
  }
}

/// One laid-out block of a legal document.
///
/// The shipped documents use six Markdown constructs — `#`, `##`, paragraphs,
/// `**strong**`, `` `code` ``, and `- ` bullets — so Dash lays them out itself
/// instead of linking a Markdown engine. Foundation still parses the *inline*
/// syntax; only the block split is hand-rolled, because `Text` honours
/// `inlinePresentationIntent` but ignores `presentationIntent` and so will
/// never lay out a heading or a list on its own.
struct LegalBlock: Identifiable {
  /// Position in the parsed document, which is also how a block finds the
  /// predecessor that decides the air above it.
  let id: Int
  let kind: LegalBlockKind
  let text: AttributedString

  /// Splits a document into blocks. Source lines are hard-wrapped at ~78
  /// columns, so the lines of one block are joined back into a single string
  /// and left to SwiftUI to wrap. A line matching nothing becomes paragraph
  /// text rather than disappearing.
  static func blocks(from markdown: String) -> [LegalBlock] {
    var blocks: [LegalBlock] = []
    var kind: LegalBlockKind = .paragraph
    var lines: [String] = []

    func emit(_ blockKind: LegalBlockKind, _ raw: String) {
      blocks.append(
        LegalBlock(id: blocks.count, kind: blockKind, text: styledInline(raw, as: blockKind)))
    }

    func flush() {
      guard !lines.isEmpty else { return }
      emit(kind, lines.joined(separator: " "))
      lines = []
    }

    for rawLine in markdown.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        flush()
      } else if let heading = line.strippingPrefix("## ") {
        flush()
        emit(.section, heading)
      } else if let heading = line.strippingPrefix("# ") {
        flush()
        emit(.title, heading)
      } else if let item = line.strippingPrefix("- ") {
        // A new bullet closes whatever block was open; the lines after it are
        // that bullet's wrapped continuation.
        flush()
        kind = .bullet
        lines = [item]
      } else {
        if lines.isEmpty { kind = .paragraph }
        lines.append(line)
      }
    }
    flush()
    return blocks
  }
}

/// Parses one block's inline Markdown and applies the document's inline styles.
private func styledInline(_ raw: String, as kind: LegalBlockKind) -> AttributedString {
  var text =
    (try? AttributedString(
      markdown: raw,
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)))
    ?? AttributedString(raw)

  // Ranges are collected up front: writing to `text` invalidates the run view
  // being iterated.
  let emphasized = text.runs.filter {
    $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
  }.map(\.range)
  let code = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
    .map(\.range)
  let links = text.runs.filter { $0.link != nil }.map(\.range)

  for range in emphasized {
    text[range].foregroundColor = DashTheme.strong
    if let font = kind.emphasizedFont { text[range].font = font }
  }
  for range in code {
    text[range].font = .system(kind.textStyle, design: .monospaced)
    // A run background is the only way to tint inline code inside one `Text`;
    // it is also what the old Markdown theme's `BackgroundColor` set.
    text[range].backgroundColor = DashTheme.recessed
  }
  for range in links {
    text[range].foregroundColor = DashTheme.brand
  }
  return text
}

extension String {
  /// `dropFirst` on a matched prefix, or nil when the prefix does not match.
  fileprivate func strippingPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}

/// Parsed documents are memoized: they ship in the bundle and never change,
/// while `body` runs on any parent update — the previous screen read the file
/// off disk and re-parsed it on every body evaluation.
@MainActor
private enum LegalDocumentStore {
  private static var parsed: [LegalDocument: [LegalBlock]] = [:]

  static func blocks(for document: LegalDocument) -> [LegalBlock] {
    if let cached = parsed[document] { return cached }
    let blocks = LegalBlock.blocks(from: LegalDocument.markdown(for: document))
    parsed[document] = blocks
    return blocks
  }
}

struct LegalDocumentView: View {
  let document: LegalDocument

  /// Leading that matches the 0.22em the document theme has always used at 15pt.
  private static let lineSpacing: CGFloat = 3

  var body: some View {
    let blocks = LegalDocumentStore.blocks(for: document)
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(blocks) { block in
          row(block, after: block.id > 0 ? blocks[block.id - 1].kind : nil)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .background(DashTheme.canvas)
    .navigationTitle(document.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func row(_ block: LegalBlock, after previous: LegalBlockKind?) -> some View {
    Group {
      if block.kind == .bullet {
        HStack(alignment: .firstTextBaseline, spacing: DashTheme.Spacing.compact) {
          Text(verbatim: "•")
          Text(block.text)
        }
      } else {
        Text(block.text)
      }
    }
    .font(block.kind.font)
    .foregroundStyle(block.kind.color)
    .lineSpacing(Self.lineSpacing)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, block.kind.spacing(after: previous))
  }
}
