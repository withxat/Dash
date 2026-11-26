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
/// `accessory` slot is the tray's fixed action band, under the scrolling
/// fields — if it has buttons, the primary verb is a `DashActionButton` and the
/// rest are `DashTrayPillButton`s, and the primary `DashActionButton` stays
/// bottom-most (reversible pills above it).
struct DashDetailTray<Accessory: View>: View {
  let fields: [DashDetailField]
  var deleteMessage: String?
  var deletePhase: DashActionPhase
  var onDeleteSuccessPresentationCompleted: (@MainActor () -> Void)?
  /// Failure of the last delete attempt, shown inline while confirming so the
  /// tray stays open instead of pretending success.
  var deleteError: String?
  var onDelete: (() -> Void)?
  let accessory: Accessory
  @State private var confirmingDelete = false

  init(
    fields: [DashDetailField],
    deleteMessage: String? = nil,
    deletePhase: DashActionPhase = .idle,
    onDeleteSuccessPresentationCompleted: (@MainActor () -> Void)? = nil,
    deleteError: String? = nil,
    onDelete: (() -> Void)? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.fields = fields
    self.deleteMessage = deleteMessage
    self.deletePhase = deletePhase
    self.onDeleteSuccessPresentationCompleted = onDeleteSuccessPresentationCompleted
    self.deleteError = deleteError
    self.onDelete = onDelete
    self.accessory = accessory()
  }

  private var hasDelete: Bool { deleteMessage != nil && onDelete != nil }

  var body: some View {
    DashConfirmMorph(
      confirming: $confirmingDelete,
      message: deleteMessage,
      actionPhase: deletePhase,
      onSuccessPresentationCompleted: onDeleteSuccessPresentationCompleted,
      actionTitle: nil,
      confirmingActionTitle: "Delete",
      confirmingActionRole: .destructive,
      actionEnabled: true,
      errorMessage: deleteError,
      action: { onDelete?() },
      headerDelete: hasDelete,
      // The accessory is the tray's action band, not the end of its fields:
      // pinned, so a long field list scrolls under buttons that stay put.
      accessory: { accessory },
      content: {
        // No inner ScrollView — DashConfirmMorph's scroll boundary owns it.
        DashDetailFieldList(fields: fields)
      }
    )
  }
}

/// Shared label/value rows used by `DashDetailTray` and custom confirm trays
/// such as `WorkerDetailView`'s deployment switcher.
struct DashDetailFieldList: View {
  let fields: [DashDetailField]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
        fieldRow(field)
        if index < fields.count - 1 { DashListGroupDivider() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func fieldRow(_ field: DashDetailField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // Labels are Dash's own copy and localize here, matching DashControlSurface.
      // Values are Cloudflare's data — hostnames, sizes, ETags — and stay verbatim.
      Text(DashL10n.ui(field.label))
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
    deletePhase: DashActionPhase = .idle,
    onDeleteSuccessPresentationCompleted: (@MainActor () -> Void)? = nil,
    deleteError: String? = nil,
    onDelete: (() -> Void)? = nil
  ) {
    self.init(
      fields: fields, deleteMessage: deleteMessage,
      deletePhase: deletePhase,
      onDeleteSuccessPresentationCompleted: onDeleteSuccessPresentationCompleted,
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
        DashDetailField(
          label: "Uploaded",
          value: DashDateFormatting.dateAndTime(fromISO8601: $0))
      },
      etag.map { DashDetailField(label: "ETag", value: $0, mono: true) },
    ].compactMap { $0 }
  }
}

extension AuditLogEntry {
  var detailFields: [DashDetailField] {
    var fields: [DashDetailField] = []
    if let actionType = action?.type, !actionType.isEmpty {
      fields.append(DashDetailField(label: "Action", value: actionType, mono: true))
    }
    if let result = action?.result, !result.isEmpty {
      let display = StatusToken(auditResult: result)?.label ?? result
      fields.append(DashDetailField(label: "Result", value: display))
    }
    if let occurredAt, !occurredAt.isEmpty {
      fields.append(
        DashDetailField(
          label: "Time",
          value: DashDateFormatting.dateAndTime(fromISO8601: occurredAt)))
    }
    if let actorName = actor?.email ?? actor?.type, !actorName.isEmpty {
      fields.append(DashDetailField(label: "Actor", value: actorName))
    }
    if let tokenName = actor?.tokenName, !tokenName.isEmpty {
      fields.append(DashDetailField(label: "API token", value: tokenName))
    }
    if let context = actor?.context, !context.isEmpty {
      fields.append(DashDetailField(label: "Context", value: context, mono: true))
    }
    if let ipAddress = actor?.ipAddress, !ipAddress.isEmpty {
      fields.append(DashDetailField(label: "IP address", value: ipAddress, mono: true))
    }
    if let product = resource?.product, !product.isEmpty {
      fields.append(DashDetailField(label: "Product", value: product))
    }
    if let resourceType = resource?.type, !resourceType.isEmpty {
      fields.append(DashDetailField(label: "Resource type", value: resourceType, mono: true))
    }
    if let resourceID = resource?.id, !resourceID.isEmpty {
      fields.append(DashDetailField(label: "Resource ID", value: resourceID, mono: true))
    }
    if let zoneName, !zoneName.isEmpty {
      fields.append(DashDetailField(label: "Domain", value: zoneName))
    }
    if let scope = resource?.scope, !scope.isEmpty {
      fields.append(DashDetailField(label: "Scope", value: scope, mono: true))
    }
    if let interfaceName, !interfaceName.isEmpty {
      fields.append(DashDetailField(label: "Interface", value: interfaceName))
    }
    if let method, !method.isEmpty, let uri, !uri.isEmpty {
      fields.append(DashDetailField(label: "Request", value: "\(method) \(uri)", mono: true))
    } else if let uri, !uri.isEmpty {
      fields.append(DashDetailField(label: "Request", value: uri, mono: true))
    }
    if let statusCode {
      fields.append(DashDetailField(label: "HTTP status", value: String(statusCode), mono: true))
    }
    if let rayID, !rayID.isEmpty {
      fields.append(DashDetailField(label: "Ray ID", value: rayID, mono: true))
    }
    if let oldValue, !oldValue.isEmpty {
      fields.append(DashDetailField(label: "Previous value", value: oldValue, mono: true))
    }
    if let newValue, !newValue.isEmpty {
      fields.append(DashDetailField(label: "New value", value: newValue, mono: true))
    }
    if let logID, !logID.isEmpty {
      fields.append(DashDetailField(label: "Event ID", value: logID, mono: true))
    }
    return fields
  }

  /// Plain-text key/value dump for Copy details.
  var copyableSummary: String {
    ([title] + detailFields.map { "\(DashL10n.ui($0.label)): \($0.value)" })
      .joined(separator: "\n")
  }
}

extension FirewallSecurityEvent {
  /// Compact headline for list rows and the detail tray title.
  var displayTitle: String {
    if let method, let fullPath {
      return "\(method) \(fullPath)"
    }
    if let fullPath { return fullPath }
    if let host { return host }
    if let clientIP { return clientIP }
    return ruleID ?? action
  }

  /// Formatted ASN value combining number and owner when available.
  var formattedASN: String? {
    switch (clientASN, clientASNDescription) {
    case (let asn?, let desc?):
      return "AS\(asn) · \(desc)"
    case (let asn?, nil):
      return "AS\(asn)"
    case (nil, let desc?):
      return desc
    case (nil, nil):
      return nil
    }
  }

  var detailFields: [DashDetailField] {
    var fields: [DashDetailField] = [
      DashDetailField(label: "Action", value: action, mono: true),
      DashDetailField(
        label: "Time",
        value: DashDateFormatting.dateAndTime(fromISO8601: datetime)),
    ]
    if let clientIP {
      fields.append(DashDetailField(label: "Client IP", value: clientIP, mono: true))
    }
    if let clientCountryName {
      fields.append(DashDetailField(label: "Country", value: clientCountryName))
    }
    if let formattedASN {
      fields.append(DashDetailField(label: "ASN", value: formattedASN))
    }
    if let requestLine {
      fields.append(DashDetailField(label: "Request", value: requestLine, mono: true))
    }
    if let source {
      fields.append(DashDetailField(label: "Source", value: source, mono: true))
    }
    if let ruleID {
      fields.append(DashDetailField(label: "Rule ID", value: ruleID, mono: true))
    }
    if let userAgent {
      fields.append(DashDetailField(label: "User-Agent", value: userAgent, mono: true))
    }
    if let edgeColoName {
      fields.append(DashDetailField(label: "Datacenter", value: edgeColoName, mono: true))
    }
    if let rayName {
      fields.append(DashDetailField(label: "Ray ID", value: rayName, mono: true))
    }
    return fields
  }

  var copyableSummary: String {
    ([displayTitle] + detailFields.map { "\(DashL10n.ui($0.label)): \($0.value)" })
      .joined(separator: "\n")
  }
}
