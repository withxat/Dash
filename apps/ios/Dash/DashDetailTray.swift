import CloudflareAPI
import SwiftUI

/// One label/value pair in a resource detail tray. Values wrap fully (no line
/// limit) and stay selectable; `mono` renders monospaced for ids, hashes, tags.
struct DashDetailField {
  let label: String
  let value: String
  var mono = false
}

/// Tray content that lays a resource out as full, selectable label/value rows —
/// the readable home for information that a single `DashListRow` truncates. A
/// read-only tray shows no action button; when a delete is supplied, a header
/// trash button morphs the fields into a single-Confirm confirmation. The
/// `accessory` slot renders below the fields — if it has buttons, the primary
/// verb is a `DashActionButton` and the rest are `DashTrayPillButton`s.
struct DashDetailTray<Accessory: View>: View {
  let fields: [DashDetailField]
  var deleteMessage: String?
  var isDeleting: Bool
  /// Failure of the last delete attempt, shown inline while confirming so the
  /// tray stays open instead of pretending success.
  var deleteError: String?
  var onDelete: (() -> Void)?
  let accessory: Accessory
  @State private var confirmingDelete = false

  init(
    fields: [DashDetailField],
    deleteMessage: String? = nil,
    isDeleting: Bool = false,
    deleteError: String? = nil,
    onDelete: (() -> Void)? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.fields = fields
    self.deleteMessage = deleteMessage
    self.isDeleting = isDeleting
    self.deleteError = deleteError
    self.onDelete = onDelete
    self.accessory = accessory()
  }

  private var hasDelete: Bool { deleteMessage != nil && onDelete != nil }

  var body: some View {
    DashConfirmMorph(
      confirming: $confirmingDelete,
      message: deleteMessage,
      isBusy: isDeleting,
      actionTitle: nil,
      confirmingActionTitle: "Delete",
      confirmingActionRole: .destructive,
      actionEnabled: true,
      errorMessage: deleteError,
      action: { onDelete?() },
      headerDelete: hasDelete,
      content: {
        // No inner ScrollView — the enclosing DashSheetCard scrolls the body.
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
              fieldRow(field)
              if index < fields.count - 1 { DashListGroupDivider() }
            }
          }
          accessory
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    )
  }

  private func fieldRow(_ field: DashDetailField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(field.label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Text(field.value)
        .dashTextStyle(field.mono ? .code : .supporting)
        .foregroundStyle(DashTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension DashDetailTray where Accessory == EmptyView {
  init(
    fields: [DashDetailField],
    deleteMessage: String? = nil,
    isDeleting: Bool = false,
    deleteError: String? = nil,
    onDelete: (() -> Void)? = nil
  ) {
    self.init(
      fields: fields, deleteMessage: deleteMessage, isDeleting: isDeleting,
      deleteError: deleteError, onDelete: onDelete,
      accessory: { EmptyView() })
  }
}

// MARK: - Field builders

extension R2Object {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Key", value: key, mono: true),
      size.map {
        DashDetailField(
          label: "Size",
          value: ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))
      },
      uploaded.map {
        DashDetailField(label: "Uploaded", value: Self.formattedUploadDate($0))
      },
      etag.map { DashDetailField(label: "ETag", value: $0, mono: true) },
    ].compactMap { $0 }
  }

  /// Cloudflare returns `last_modified` as ISO 8601 (with or without fractional
  /// seconds). Show a local date + short time instead of the raw stamp.
  private static func formattedUploadDate(_ iso: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else {
      return iso
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}

extension String {
  /// snake_case / kebab-case → "Title Case"; matches the app's existing
  /// `ZoneSetting.displayTitle` convention (Cloudflare keys are snake_case).
  fileprivate var humanizedFieldLabel: String {
    replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .capitalized
  }

  /// Identifier-like keys read better monospaced.
  fileprivate var isMonoKey: Bool {
    ["id", "uuid", "tag", "sitekey", "key", "hash", "token", "etag"].contains(lowercased())
  }
}
