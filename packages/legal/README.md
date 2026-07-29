# @dash/legal

Canonical legal documents for Dash.

- `PrivacyPolicy.md` is published at `https://dash.xat.sh/privacy`.
- `TermsOfUse.md` is published at `https://dash.xat.sh/terms`.
- The iOS resource paths are tracked symlinks to these files, so the in-app
  documents and public pages ship from the same source.

Update the effective date in the Markdown document whenever its terms change.

## Supported syntax

The web pages render these files with `react-markdown`, but the iOS app lays
them out itself (`LegalDocumentView`) and accepts exactly six constructs:

`#` · `##` · paragraphs · `**strong**` · `` `code` `` · `- ` bullets

Anything else — tables, blockquotes, fenced code, images, ordered lists, nested
lists, `###` and deeper, `*` bullets — renders on the web and degrades to
literal text in the app. `legalDocumentsStayInsideTheSyntaxDashCanRender` in
`DashTests` fails on that, so `pnpm ios:test` catches it rather than a reader.
Paragraphs may stay hard-wrapped; the app rejoins wrapped lines.
