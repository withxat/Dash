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
/// trash button morphs the fields into a single-Confirm confirmation.
struct DashDetailTray: View {
  let fields: [DashDetailField]
  var deleteMessage: String? = nil
  var isDeleting = false
  var onDelete: (() -> Void)? = nil
  @State private var confirmingDelete = false

  private var hasDelete: Bool { deleteMessage != nil && onDelete != nil }

  var body: some View {
    ZStack {
      if confirmingDelete, let deleteMessage, let onDelete {
        VStack(spacing: 16) {
          Text(deleteMessage)
            .font(.system(size: 15))
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

          VStack(spacing: 4) {
            Button {
              withAnimation(DashTheme.Motion.morph) { confirmingDelete = false }
            } label: {
              Text("Cancel")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DashTheme.subtle)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(DashPressButtonStyle())

            DashActionButton(
              title: "Confirm", role: .destructive, isLoading: isDeleting, action: onDelete)
          }
        }
        .padding(.horizontal, DashTheme.Sheet.content)
        .padding(.bottom, DashTheme.Sheet.bodyBottom)
        .transition(.dashMorph)
      } else {
        // No inner ScrollView — the enclosing DashSheetCard scrolls the body.
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
            fieldRow(field)
            if index < fields.count - 1 { DashListGroupDivider() }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DashTheme.Sheet.content)
        .padding(.bottom, DashTheme.Sheet.bodyBottom)
        .transition(.dashMorph)
      }
    }
    .dashTrayHeaderAction(
      hasDelete && !confirmingDelete
        ? DashSheetHeaderAction(
          id: "delete", icon: SolarAsset.trash, accessibilityLabel: "Delete"
        ) {
          withAnimation(DashTheme.Motion.morph) { confirmingDelete = true }
        }
        : nil
    )
  }

  private func fieldRow(_ field: DashDetailField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(field.label)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DashTheme.subtle)
      Text(field.value)
        .font(field.mono ? .system(size: 14, design: .monospaced) : .system(size: 15))
        .foregroundStyle(DashTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Field builders

extension GenericResource {
  /// Every field the endpoint returned, well-known keys first, then the rest
  /// alphabetically. Empty and null values are dropped.
  var detailFields: [DashDetailField] {
    let preferred = [
      "name", "title", "hostname", "email", "id", "uuid", "tag",
      "status", "state", "type", "description", "created_on", "modified_on",
    ]
    var seen = Set<String>()
    var fields: [DashDetailField] = []

    func add(_ key: String) {
      guard !seen.contains(key), let value = raw[key] else { return }
      let text = value.displayText
      guard !text.isEmpty, text != "Not set", text != "None" else { return }
      seen.insert(key)
      fields.append(
        DashDetailField(label: key.humanizedFieldLabel, value: text, mono: key.isMonoKey))
    }

    for key in preferred { add(key) }
    for key in raw.keys.sorted() { add(key) }
    return fields
  }
}

extension AuditLogEntry {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Action", value: action?.type ?? "—"),
      actor?.email.map { DashDetailField(label: "Actor", value: $0) },
      actor?.type.map { DashDetailField(label: "Actor type", value: $0) },
      resource?.type.map { DashDetailField(label: "Resource", value: $0) },
      logID.map { DashDetailField(label: "Log ID", value: $0, mono: true) },
    ].compactMap { $0 }
  }
}

extension NotificationHistoryEntry {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Alert", value: title),
      alertType.map { DashDetailField(label: "Type", value: $0) },
      mechanism.map { DashDetailField(label: "Mechanism", value: $0) },
      alertBody.map { DashDetailField(label: "Body", value: $0) },
      description.map { DashDetailField(label: "Description", value: $0) },
      sent.map { DashDetailField(label: "Sent", value: $0) },
      policyID.map { DashDetailField(label: "Policy ID", value: $0, mono: true) },
    ].compactMap { $0 }
  }
}

extension NotificationPolicy {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Policy", value: title),
      alertType.map { DashDetailField(label: "Type", value: $0) },
      DashDetailField(label: "ID", value: id, mono: true),
    ].compactMap { $0 }
  }
}

extension AccountMember {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Name", value: displayName),
      user?.email.map { DashDetailField(label: "Email", value: $0) },
      roleSummary.map { DashDetailField(label: "Roles", value: $0) },
      DashDetailField(label: "Member ID", value: id, mono: true),
    ].compactMap { $0 }
  }
}

extension CloudflareImage {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Name", value: name),
      uploaded.map { DashDetailField(label: "Uploaded", value: $0) },
      DashDetailField(
        label: "Signed URLs", value: requireSignedURLs == true ? "Required" : "Not required"),
      DashDetailField(label: "ID", value: id, mono: true),
    ].compactMap { $0 }
  }
}

extension StreamVideo {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Name", value: name),
      created.map { DashDetailField(label: "Created", value: $0) },
      DashDetailField(label: "UID", value: uid, mono: true),
    ].compactMap { $0 }
  }
}

extension RumSite {
  var detailFields: [DashDetailField] {
    [
      host.map { DashDetailField(label: "Host", value: $0) },
      siteTag.map { DashDetailField(label: "Site tag", value: $0, mono: true) },
    ].compactMap { $0 }
  }
}

extension R2Object {
  var detailFields: [DashDetailField] {
    [
      DashDetailField(label: "Key", value: key, mono: true),
      size.map {
        DashDetailField(
          label: "Size",
          value: ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))
      },
      uploaded.map { DashDetailField(label: "Uploaded", value: $0) },
      etag.map { DashDetailField(label: "ETag", value: $0, mono: true) },
    ].compactMap { $0 }
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
