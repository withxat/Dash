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

/// Settings → Help & about → Data & Privacy, also opened from the sign-in
/// footer: what leaves this iPhone, where it goes, and what stays behind.
///
/// It may only state what the code does. Every host listed is one the app
/// actually contacts on its own, and the footnote admits the one thing the
/// relay does see — the single-use authorization code — rather than claiming
/// it sees nothing. Change a network path and change this page with it; the
/// Privacy Policy stays the binding wording.
struct DataPrivacyView: View {
  static let sourceCode = URL(string: "https://github.com/withxat/Dash")!

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        DataPrivacyHero()

        DashTwoToneListGroup(title: "Sign-in") {
          DataPrivacyFact(
            title: DashL10n.string("Signed in on Cloudflare"),
            detail: DashL10n.string(
              "OAuth with PKCE. Dash never sees your password."),
            icon: SolarAsset.Content.user,
            color: DashTheme.info
          )
          DataPrivacyFact(
            title: DashL10n.string("Stays in your Keychain"),
            detail: DashL10n.string(
              "Never synced to iCloud, and sent only to Cloudflare."
            ),
            icon: SolarAsset.Content.lock,
            color: DashTheme.success
          )
          DataPrivacyFact(
            title: DashL10n.string("Cleared when you sign out"),
            detail: DashL10n.string(
              "Dash deletes the token and your cached data, and asks Cloudflare to revoke it."),
            icon: SolarAsset.Content.key,
            color: DashTheme.warning
          )
        }

        VStack(alignment: .leading, spacing: 10) {
          // Host names are addresses, not copy: they render verbatim.
          DashInfoGroup(title: "Where requests go") {
            DashInfoRow("Account data", value: "api.cloudflare.com", mono: true)
            DashInfoRow("Sign-in & tokens", value: "dash.cloudflare.com", mono: true)
            DashInfoRow("Sign-in redirect", value: "dash.xat.sh", mono: true)
            DashInfoRow("Registration lookup", value: "dash.xat.sh", mono: true)
            DashInfoRow("Avatar", value: "gravatar.com", mono: true)
            DashInfoRow("Cloudflare status", value: "cloudflarestatus.com", mono: true)
          }

          Text(
            DashL10n.string(
              "dash.xat.sh stores nothing and never sees your token, only a single-use sign-in code. Gravatar gets only a hash of your email."
            )
          )
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
        }

        DashTwoToneListGroup(title: "Code") {
          DataPrivacyFact(
            title: DashL10n.string("No analytics or tracking"),
            detail: DashL10n.string(
              "No ad, analytics, or crash-reporting SDKs."),
            icon: SolarAsset.Content.graph,
            color: DashTheme.violet
          )
          DataPrivacySourceRow()
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.shieldCheck), title: "Data & Privacy")
  }
}

/// The page's thesis drawn before it is written: this iPhone and Cloudflare,
/// one locked line between them, then the headline. The diagram is decoration
/// for sighted readers; VoiceOver gets the headline and the facts below it.
private struct DataPrivacyHero: View {
  @ScaledMetric(relativeTo: .title2) private var nodeSize: CGFloat = 60

  private var badgeSize: CGFloat { nodeSize * 0.46 }

  var body: some View {
    VStack(spacing: 22) {
      HStack(alignment: .top, spacing: 0) {
        endpoint(
          label: DashL10n.string("This iPhone"),
          glyph: SolarIcon(
            asset: SolarAsset.smartphone, size: nodeSize * 0.44, color: DashTheme.text))
        link
          .frame(height: nodeSize)
        endpoint(
          label: "Cloudflare",
          glyph: SolarIcon(
            asset: SolarAsset.cloudflare, size: nodeSize * 0.52, color: DashTheme.accent))
      }
      .frame(maxWidth: 300)
      .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text(DashL10n.string("Between this iPhone and Cloudflare"))
          .dashTextStyle(.emptyTitle)
          .foregroundStyle(DashTheme.strong)
          .accessibilityAddTraits(.isHeader)
        Text(
          DashL10n.string(
            "Dash has no account system and no server keeping your data."
          )
        )
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }

  private func endpoint(label: String, glyph: SolarIcon) -> some View {
    VStack(spacing: 10) {
      glyph
        .frame(width: nodeSize, height: nodeSize)
        .background(DashTheme.homeCardSurface, in: Circle())
        .dashEmbossChrome(shape: Circle())
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
        .lineLimit(1)
        .fixedSize()
    }
    .frame(width: nodeSize + 36)
  }

  /// The connection: a line warming from the phone's neutral to Cloudflare's
  /// orange, locked at the middle.
  private var link: some View {
    ZStack {
      Capsule()
        .fill(
          LinearGradient(
            colors: [DashTheme.iconMuted.opacity(0.35), DashTheme.accent.opacity(0.7)],
            startPoint: .leading, endPoint: .trailing)
        )
        .frame(height: 2)
      SolarIcon(asset: SolarAsset.Content.lock, size: badgeSize * 0.5, color: DashTheme.success)
        .frame(width: badgeSize, height: badgeSize)
        .background(DashTheme.successTint, in: Circle())
        .dashShadow(.border, in: Circle())
    }
    .frame(maxWidth: .infinity)
  }
}

/// One promise on a two-tone card: a tinted plate, a short claim, and the
/// sentence that makes it checkable. Not a `DashListRow`: that row caps its
/// subtitle at two lines, and a privacy claim must never end in an ellipsis.
private struct DataPrivacyFact: View {
  let title: String
  let detail: String
  let icon: String
  let color: Color
  var opensExternally = false
  @ScaledMetric(relativeTo: .body) private var iconScale: CGFloat = 1

  private var plate: CGFloat { 36 * min(max(iconScale, 1), 1.3) }

  var body: some View {
    HStack(spacing: 12) {
      SolarIcon(asset: icon, size: plate * 2 / 3, color: color)
        .frame(width: plate, height: plate)
        .background(color.opacity(0.1), in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
        Text(detail)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      if opensExternally {
        SolarIcon(
          asset: SolarAsset.arrowRightUp, size: DashTheme.Chevron.row,
          color: DashTheme.placeholder)
      }
    }
    .padding(.vertical, 10)
    .frame(minHeight: DashTheme.Layout.twoToneListRow)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

private struct DataPrivacySourceRow: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      openURL(DataPrivacyView.sourceCode)
    } label: {
      DataPrivacyFact(
        title: DashL10n.string("Open source"),
        detail: DashL10n.string("MIT license, on GitHub."),
        icon: SolarAsset.Content.code,
        color: DashTheme.text,
        opensExternally: true
      )
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityHint(DashL10n.string("Opens the project repository in your browser"))
    .accessibilityIdentifier("data-privacy-source")
  }
}
