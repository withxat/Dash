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
/// `accessory` slot renders below the fields (e.g. a Download share link).
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
      confirmingActionTitle: "Confirm",
      confirmingActionRole: .destructive,
      actionEnabled: true,
      errorMessage: deleteError,
      action: { onDelete?() },
      headerDelete: hasDelete
    ) {
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

enum GenericDetailFieldMap {
  /// High-value keys shown by default in resource detail trays.
  static let preferredKeys = [
    "name", "title", "hostname", "email", "status", "state", "type", "description",
    "created_on", "modified_on",
  ]

  static func primaryFields(from resource: GenericResource) -> [DashDetailField] {
    fields(from: resource, keys: preferredKeys, includeRemainder: false)
  }

  static func advancedFields(from resource: GenericResource) -> [DashDetailField] {
    let preferred = Set(preferredKeys)
    let remainder = resource.raw.keys.sorted().filter { !preferred.contains($0) }
    return fields(from: resource, keys: remainder, includeRemainder: false)
  }

  static func fields(
    from resource: GenericResource, keys: [String], includeRemainder: Bool
  ) -> [DashDetailField] {
    var seen = Set<String>()
    var fields: [DashDetailField] = []

    func add(_ key: String) {
      guard !seen.contains(key), let value = resource.raw[key] else { return }
      let text = value.displayText
      guard !text.isEmpty, text != "Not set", text != "None" else { return }
      seen.insert(key)
      fields.append(
        DashDetailField(label: key.humanizedFieldLabel, value: text, mono: key.isMonoKey))
    }

    for key in keys { add(key) }
    if includeRemainder {
      for key in resource.raw.keys.sorted() { add(key) }
    }
    return fields
  }

  static func humanCategoryTitle(_ raw: String) -> String {
    switch raw.lowercased() {
    case "account": "Account"
    case "dns", "domains & dns", "zones": "DNS"
    case "workers", "workers & pages", "compute": "Workers"
    case "storage", "r2", "kv", "d1": "Storage"
    case "security", "zero trust", "access": "Security"
    case "ai", "artificial intelligence": "AI"
    case "network", "networking": "Network"
    case "analytics", "observability": "Analytics"
    default: raw
    }
  }
}

extension GenericResource {
  /// Every field the endpoint returned, well-known keys first, then the rest
  /// alphabetically. Empty and null values are dropped.
  var detailFields: [DashDetailField] {
    GenericDetailFieldMap.fields(
      from: self, keys: GenericDetailFieldMap.preferredKeys, includeRemainder: true)
  }

  var primaryDetailFields: [DashDetailField] {
    GenericDetailFieldMap.primaryFields(from: self)
  }

  var advancedDetailFields: [DashDetailField] {
    GenericDetailFieldMap.advancedFields(from: self)
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
      enabled.map { DashDetailField(label: "Enabled", value: $0 ? "On" : "Off") },
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
