import CloudflareAPI
import SwiftUI
import UIKit

/// Pure validation and normalization helpers for Worker secrets and Cron Triggers,
/// kept out of SwiftUI views so edge cases stay unit-tested.
enum WorkerConfigurationRules {
  static let cronPresets: [(label: String, cron: String)] = [
    ("Every 5 min", "*/5 * * * *"),
    ("Hourly", "0 * * * *"),
    ("Daily (00:00 UTC)", "0 0 * * *"),
  ]

  static func normalizedSecretName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Cloudflare Worker binding identifiers must be valid JS-style ASCII names
  /// (letters, digits, underscores, starting with a letter or underscore).
  static func isValidSecretName(_ raw: String) -> Bool {
    let name = normalizedSecretName(raw)
    guard let first = name.first else { return false }
    guard first.isASCII, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
  }

  static func normalizedCronExpression(_ raw: String) -> String {
    raw
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .joined(separator: " ")
  }

  /// Standard 5-field Cloudflare Cron expression (`minute hour day month weekday`).
  static func isValidCronExpression(_ raw: String) -> Bool {
    let fields = raw.split(whereSeparator: \.isWhitespace)
    guard fields.count == 5 else { return false }
    return fields.allSatisfy { field in
      !field.isEmpty
        && field.allSatisfy { ch in
          ch.isASCII
            && (ch.isNumber || ch.isLetter || ch == "*" || ch == "/" || ch == "," || ch == "-")
        }
    }
  }
}

struct WorkerConfigurationSnapshot: Codable, Hashable, Sendable {
  var settings: WorkerSettings?
  var secrets: [WorkerSecret]
  var schedules: [WorkerCronTrigger]

  var nonSecretBindings: [WorkerBinding] {
    (settings?.bindings ?? []).filter { !$0.isSecret }
  }

  var hasRuntimeDetails: Bool {
    guard let settings else { return false }
    return settings.compatibilityDate != nil
      || !settings.compatibilityFlags.isEmpty
      || settings.placementMode != nil
      || settings.logpush != nil
  }
}

/// Worker runtime settings, bindings, write-only secrets, and Cron Triggers.
/// Uses the Workers feature's existing `workers-scripts.read` / `.write` scopes.
struct WorkerConfigurationView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let name: String

  @State private var settings: WorkerSettings?
  @State private var secrets: [WorkerSecret] = []
  @State private var schedules: [WorkerCronTrigger] = []
  @State private var loading = true
  @State private var hasPresentedContent = false
  @State private var error: String?
  @State private var settingsError: String?
  @State private var secretsError: String?
  @State private var schedulesError: String?
  @State private var loadedContext: AccountRequestContext?

  @State private var selectedBinding: WorkerBinding?
  @State private var selectedSecret: WorkerSecret?
  @State private var showsAddSecret = false
  @State private var selectedCron: WorkerCronTrigger?
  @State private var showsAddCron = false

  @State private var deleteSecretPhase: DashActionPhase = .idle
  @State private var deleteSecretError: String?
  @State private var deleteCronPhase: DashActionPhase = .idle
  @State private var deleteCronError: String?

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .workerConfiguration(name))
  }

  private var allowsWrites: Bool {
    featureAllowsWrites && model.hasScopes(requiredWriteScopes)
  }

  private var nonSecretBindings: [WorkerBinding] {
    (settings?.bindings ?? []).filter { !$0.isSecret }
  }

  private var hasRuntimeDetails: Bool {
    guard let settings else { return false }
    return settings.compatibilityDate != nil
      || !settings.compatibilityFlags.isEmpty
      || settings.placementMode != nil
      || settings.logpush != nil
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: hasPresentedContent,
      retry: { Task { await load(force: true) } }
    ) { mode in
      configurationBody(mode: mode)
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.slider),
      title: "Bindings & triggers",
      tint: FeatureVisualIdentity.heroColor(for: .workers)
    )
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
    .dashTray(
      item: $selectedBinding,
      title: { $0.name },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { binding in
        WorkerBindingDetailTray(binding: binding)
      }
    )
    .dashTray(
      item: $selectedSecret,
      title: { $0.name },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { secret in
        secretTrayContent(secret)
      }
    )
    .dashTray(
      isPresented: $showsAddSecret,
      title: "Add secret",
      tone: FeatureVisualIdentity.tone(for: .workers)
    ) {
      WorkerSecretForm(
        workerName: name,
        existingSecret: nil,
        allowsWrites: allowsWrites,
        onSaved: {
          invalidateCache()
          Task { await load(force: true) }
        }
      )
    }
    .dashTray(
      item: $selectedCron,
      title: { $0.cron },
      tone: FeatureVisualIdentity.tone(for: .workers),
      content: { trigger in
        cronDetailTray(trigger)
      }
    )
    .dashTray(
      isPresented: $showsAddCron,
      title: "Add Cron Trigger",
      tone: FeatureVisualIdentity.tone(for: .workers)
    ) {
      WorkerCronTriggerForm(
        workerName: name,
        existingCrons: schedules.map(\.cron),
        allowsWrites: allowsWrites,
        onSaved: { updated in
          schedules = updated
          invalidateCache()
        }
      )
    }
  }

  @ViewBuilder
  private func configurationBody(mode: DashBodyMode) -> some View {
    if !mode.isPlaceholder, !allowsWrites {
      FeatureWriteAccessNotice(
        message: "Read-only — grant Workers write access to edit secrets or Cron Triggers.",
        scopes: requiredWriteScopes
      )
      .dashBodySlot(reduceMotion: reduceMotion)
    }

    if mode.isPlaceholder || hasRuntimeDetails {
      runtimeSection(mode: mode)
        .dashSectionBoundary(!mode.isPlaceholder && !allowsWrites)
        .dashBodySlot(reduceMotion: reduceMotion)
    }

    secretsSection(
      mode: mode, leadsWithBoundary: mode.isPlaceholder || hasRuntimeDetails || !allowsWrites)
    bindingsSection(mode: mode)
    cronTriggersSection(mode: mode)
  }

  @ViewBuilder
  private func runtimeSection(mode: DashBodyMode) -> some View {
    DashTwoToneListGroup(title: "Runtime") {
      if mode.isPlaceholder {
        DashToggleRowPlaceholder()
        DashToggleRowPlaceholder()
      } else if let settings {
        if let compatibilityDate = settings.compatibilityDate {
          DashValueCard(title: "Compatibility date", value: compatibilityDate)
        }
        if !settings.compatibilityFlags.isEmpty {
          DashValueCard(
            title: "Compatibility flags",
            value: settings.compatibilityFlags.joined(separator: ", "))
        }
        if let placementMode = settings.placementMode {
          DashValueCard(title: "Placement", value: DashL10n.ui(placementMode))
        }
        if let logpush = settings.logpush {
          DashValueCard(
            title: "Logpush",
            value: DashL10n.ui(logpush ? "Enabled" : "Disabled"))
        }
      }
    }
  }

  @ViewBuilder
  private func secretsSection(mode: DashBodyMode, leadsWithBoundary: Bool) -> some View {
    DashListGroupHeader(
      title: DashL10n.ui("Secrets"),
      actionTitle: !mode.isPlaceholder && allowsWrites ? DashL10n.ui("Add") : nil,
      actionIcon: !mode.isPlaceholder && allowsWrites ? SolarAsset.plus : nil,
      action: !mode.isPlaceholder && allowsWrites ? { showsAddSecret = true } : nil
    )
    .dashTwoToneHeaderBand()
    .dashSectionBoundary(leadsWithBoundary)
    .dashBodySlot(reduceMotion: reduceMotion)

    if mode.isPlaceholder || !secrets.isEmpty {
      dashModeListRows(
        mode: mode,
        items: secrets,
        placeholderRows: 2,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { secret in
        Button {
          deleteSecretPhase = .idle
          deleteSecretError = nil
          selectedSecret = secret
        } label: {
          DashListRow(
            title: secret.name,
            subtitle: DashL10n.ui(secret.isTextSecret ? "Encrypted secret" : "Secret key"),
            icon: SolarAsset.Content.lock,
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("worker-secret-\(secret.name)")
      }
    } else if let secretsError {
      sectionFailureSlice(secretsError)
    } else {
      Text("No secrets configured.")
        .dashTwoToneNote()
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  @ViewBuilder
  private func bindingsSection(mode: DashBodyMode) -> some View {
    DashListGroupHeader(title: DashL10n.ui("Bindings"))
      .dashTwoToneHeaderBand()
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)

    if mode.isPlaceholder || !nonSecretBindings.isEmpty {
      dashModeListRows(
        mode: mode,
        items: nonSecretBindings,
        placeholderRows: 2,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { binding in
        Button {
          selectedBinding = binding
        } label: {
          DashListRow(
            title: binding.name,
            subtitle: Self.bindingSubtitle(binding),
            icon: Self.bindingIcon(for: binding.type),
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("worker-binding-\(binding.name)")
      }
    } else if let settingsError {
      sectionFailureSlice(settingsError)
    } else {
      Text("No bindings configured.")
        .dashTwoToneNote()
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  @ViewBuilder
  private func cronTriggersSection(mode: DashBodyMode) -> some View {
    DashListGroupHeader(
      title: DashL10n.ui("Cron triggers"),
      actionTitle: !mode.isPlaceholder && allowsWrites ? DashL10n.ui("Add") : nil,
      actionIcon: !mode.isPlaceholder && allowsWrites ? SolarAsset.plus : nil,
      action: !mode.isPlaceholder && allowsWrites ? { showsAddCron = true } : nil
    )
    .dashTwoToneHeaderBand()
    .dashSectionBoundary()
    .dashBodySlot(reduceMotion: reduceMotion)

    if mode.isPlaceholder || !schedules.isEmpty {
      dashModeListRows(
        mode: mode,
        items: schedules,
        placeholderRows: 2,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { trigger in
        Button {
          deleteCronPhase = .idle
          deleteCronError = nil
          selectedCron = trigger
        } label: {
          DashListRow(
            title: trigger.cron,
            subtitle: Self.cronSubtitle(trigger),
            icon: SolarAsset.Content.clock,
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("worker-cron-\(trigger.cron)")
      }
    } else if let schedulesError {
      sectionFailureSlice(schedulesError)
    } else {
      Text("No Cron Triggers configured.")
        .dashTwoToneNote()
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  private func sectionFailureSlice(_ message: String) -> some View {
    DashSectionListRowPlaceholders(rows: 2)
      .dashSectionFailure(
        message,
        retry: { Task { await load(force: true) } }
      )
      .dashTwoToneRowSlice()
      .dashBodySlot(reduceMotion: reduceMotion)
  }

  @ViewBuilder
  private func secretTrayContent(_ secret: WorkerSecret) -> some View {
    if secret.isTextSecret, allowsWrites {
      WorkerSecretForm(
        workerName: name,
        existingSecret: secret,
        allowsWrites: allowsWrites,
        onSaved: {
          invalidateCache()
          Task { await load(force: true) }
        },
        onDeleted: {
          secrets.removeAll { $0.name == secret.name }
          invalidateCache()
        }
      )
    } else {
      DashDetailTray(
        fields: [
          DashDetailField(label: "Name", value: secret.name, mono: true),
          DashDetailField(
            label: "Type",
            value: DashL10n.ui(secret.isTextSecret ? "Encrypted secret" : "Secret key")),
        ],
        deleteMessage: allowsWrites
          ? DashL10n.string("Permanently remove the secret \(secret.name) from \(name)?")
          : nil,
        deletePhase: deleteSecretPhase,
        onDeleteSuccessPresentationCompleted: {
          deleteSecretPhase = .idle
          selectedSecret = nil
        },
        deleteError: deleteSecretError,
        onDelete: allowsWrites ? { Task { await deleteSecret(secret) } } : nil
      )
    }
  }

  @ViewBuilder
  private func cronDetailTray(_ trigger: WorkerCronTrigger) -> some View {
    DashDetailTray(
      fields: trigger.detailFields,
      deleteMessage: allowsWrites
        ? DashL10n.string("Remove Cron Trigger \(trigger.cron) from \(name)?")
        : nil,
      deletePhase: deleteCronPhase,
      onDeleteSuccessPresentationCompleted: {
        deleteCronPhase = .idle
        selectedCron = nil
      },
      deleteError: deleteCronError,
      onDelete: allowsWrites ? { Task { await deleteCron(trigger) } } : nil,
      accessory: {
        DashActionButton(title: "Copy expression") {
          UIPasteboard.general.string = trigger.cron
          DashDelight.lightImpact()
          model.toasts.success(DashL10n.string("Expression copied"))
        }
      }
    )
  }

  private static func bindingSubtitle(_ binding: WorkerBinding) -> String {
    let kind = DashL10n.ui(binding.kindTitle)
    if let summary = binding.summaryValue {
      return "\(kind) · \(summary)"
    }
    return kind
  }

  private static func bindingIcon(for type: String) -> String {
    switch type {
    case "kv_namespace": SolarAsset.Content.key
    case "r2_bucket": SolarAsset.Content.box
    case "service": SolarAsset.Content.code
    case "plain_text", "json": SolarAsset.Content.slider
    default: SolarAsset.Content.boxMinimalistic
    }
  }

  private static func cronSubtitle(_ trigger: WorkerCronTrigger) -> String? {
    guard let stamp = trigger.modifiedOn ?? trigger.createdOn,
      DashDateFormatting.date(fromISO8601: stamp) != nil
    else { return nil }
    return DashL10n.string("Updated \(DashDateFormatting.dateOnly(fromISO8601: stamp))")
  }

  // MARK: Loading & mutations

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    settings = nil
    secrets = []
    schedules = []
    loading = context != nil
    hasPresentedContent = false
    error = nil
    settingsError = nil
    secretsError = nil
    schedulesError = nil
    selectedBinding = nil
    selectedSecret = nil
    showsAddSecret = false
    selectedCron = nil
    showsAddCron = false
  }

  private func invalidateCache() {
    guard let accountID = model.activeAccountID else { return }
    model.featureCache.remove(
      FeatureCacheKey.workerConfiguration(accountID: accountID, name: name))
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.workerConfiguration(accountID: context.accountID, name: name)
    if !force, let cached: WorkerConfigurationSnapshot = model.featureCache.get(key) {
      settings = cached.settings
      secrets = cached.secrets
      schedules = cached.schedules
      settingsError = nil
      secretsError = nil
      schedulesError = nil
      error = nil
      hasPresentedContent = true
      loading = false
      return
    }

    if !hasPresentedContent { loading = true }
    error = nil

    let client = model.client
    let accountID = context.accountID
    let scriptName = name

    async let settingsResult: Result<WorkerSettings, any Error> = {
      do {
        return .success(
          try await client.getWorkerSettings(accountID: accountID, scriptName: scriptName))
      } catch { return .failure(error) }
    }()
    async let secretsResult: Result<[WorkerSecret], any Error> = {
      do {
        return .success(
          try await client.listWorkerSecrets(accountID: accountID, scriptName: scriptName))
      } catch { return .failure(error) }
    }()
    async let schedulesResult: Result<[WorkerCronTrigger], any Error> = {
      do {
        return .success(
          try await client.listWorkerSchedules(accountID: accountID, scriptName: scriptName))
      } catch { return .failure(error) }
    }()

    let (settingsOutcome, secretsOutcome, schedulesOutcome) = await (
      settingsResult, secretsResult, schedulesResult
    )
    guard model.isCurrentAccount(context), !Task.isCancelled else { return }

    var succeededCount = 0
    var firstError: String?

    switch settingsOutcome {
    case .success(let value):
      settings = value
      settingsError = nil
      succeededCount += 1
    case .failure(let err) where !err.dashIsCancellation:
      settingsError = err.dashActionableMessage
      if firstError == nil { firstError = settingsError }
    case .failure:
      break
    }

    switch secretsOutcome {
    case .success(let value):
      secrets = value.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      secretsError = nil
      succeededCount += 1
    case .failure(let err) where !err.dashIsCancellation:
      secretsError = err.dashActionableMessage
      if firstError == nil { firstError = secretsError }
    case .failure:
      break
    }

    switch schedulesOutcome {
    case .success(let value):
      schedules = value
      schedulesError = nil
      succeededCount += 1
    case .failure(let err) where !err.dashIsCancellation:
      schedulesError = err.dashActionableMessage
      if firstError == nil { firstError = schedulesError }
    case .failure:
      break
    }

    if succeededCount == 3 {
      model.featureCache.set(
        key,
        WorkerConfigurationSnapshot(settings: settings, secrets: secrets, schedules: schedules))
      hasPresentedContent = true
      error = nil
    } else if succeededCount > 0 {
      hasPresentedContent = true
      error = nil
    } else if !hasPresentedContent {
      error = firstError
    } else {
      error = firstError
    }

    loading = false
  }

  private func deleteSecret(_ secret: WorkerSecret) async {
    guard let context = model.accountRequestContext else { return }
    deleteSecretPhase = .loading
    deleteSecretError = nil
    do {
      try await model.client.deleteWorkerSecret(
        accountID: context.accountID, scriptName: name, secretName: secret.name)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        deleteSecretPhase = .idle
        return
      }
      secrets.removeAll { $0.name == secret.name }
      invalidateCache()
      model.toasts.success(DashL10n.string("Deleted secret \(secret.name)"))
      deleteSecretPhase = .succeeded
    } catch {
      deleteSecretPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      deleteSecretError = error.dashActionableMessage
    }
  }

  private func deleteCron(_ trigger: WorkerCronTrigger) async {
    guard let context = model.accountRequestContext else { return }
    deleteCronPhase = .loading
    deleteCronError = nil
    let remaining = schedules.map(\.cron).filter { $0 != trigger.cron }
    do {
      let updated = try await model.client.updateWorkerSchedules(
        accountID: context.accountID, scriptName: name, crons: remaining)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        deleteCronPhase = .idle
        return
      }
      schedules = updated
      invalidateCache()
      model.toasts.success(DashL10n.string("Removed Cron Trigger"))
      deleteCronPhase = .succeeded
    } catch {
      deleteCronPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      deleteCronError = error.dashActionableMessage
    }
  }
}

private struct WorkerBindingDetailTray: View {
  @Environment(AppModel.self) private var model
  let binding: WorkerBinding

  var body: some View {
    DashDetailTray(fields: binding.detailFields) {
      if let value = binding.summaryValue {
        DashActionButton(title: "Copy value") {
          UIPasteboard.general.string = value
          DashDelight.lightImpact()
          model.toasts.success(DashL10n.string("Value copied"))
        }
      }
    }
  }
}

/// Form tray for creating a new text secret or rotating / deleting an existing one.
private struct WorkerSecretForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss

  let workerName: String
  let existingSecret: WorkerSecret?
  let allowsWrites: Bool
  let onSaved: () -> Void
  var onDeleted: (() -> Void)? = nil

  @State private var secretName: String
  @State private var secretValue = ""
  @State private var revealValue = false
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?

  init(
    workerName: String,
    existingSecret: WorkerSecret?,
    allowsWrites: Bool,
    onSaved: @escaping () -> Void,
    onDeleted: (() -> Void)? = nil
  ) {
    self.workerName = workerName
    self.existingSecret = existingSecret
    self.allowsWrites = allowsWrites
    self.onSaved = onSaved
    self.onDeleted = onDeleted
    _secretName = State(initialValue: existingSecret?.name ?? "")
  }

  private var isEditing: Bool { existingSecret != nil }

  private var normalizedName: String {
    WorkerConfigurationRules.normalizedSecretName(secretName)
  }

  private var canSave: Bool {
    allowsWrites
      && WorkerConfigurationRules.isValidSecretName(normalizedName)
      && !secretValue.isEmpty
      && !actionPhase.isActive
  }

  var body: some View {
    DashFormSheet(
      saveTitle: isEditing ? "Update secret" : "Add secret",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completePresentation,
      canSave: canSave,
      deleteMessage: isEditing && allowsWrites
        ? DashL10n.string("Permanently remove the secret \(normalizedName) from \(workerName)?")
        : nil,
      deleteError: errorMessage,
      onDelete: isEditing && allowsWrites ? { Task { await delete() } } : nil,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(label: "Name", text: $secretName)
            .disabled(isEditing || actionPhase.isActive)

          if !isEditing, !normalizedName.isEmpty,
            !WorkerConfigurationRules.isValidSecretName(normalizedName)
          {
            Text(DashL10n.string("Use ASCII letters, numbers, and underscores only."))
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.danger)
              .fixedSize(horizontal: false, vertical: true)
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(DashL10n.ui(isEditing ? "New value" : "Value"))
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              Spacer()
              Button(DashL10n.string(revealValue ? "Hide" : "Show")) {
                revealValue.toggle()
              }
              .dashTextStyle(.captionSemibold)
              .foregroundStyle(DashTheme.subtle)
              .buttonStyle(DashPressButtonStyle())
            }

            Group {
              if revealValue {
                TextField(DashL10n.ui("Secret value"), text: $secretValue)
              } else {
                SecureField(DashL10n.ui("Secret value"), text: $secretValue)
              }
            }
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(actionPhase.isActive)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(DashTheme.recessed)
            .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
          }

          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string("Secret values are write-only and cannot be viewed again after saving.")
    )
  }

  private func save() async {
    guard canSave, let context = model.accountRequestContext else { return }
    let nameToSave = normalizedName
    actionPhase = .loading
    errorMessage = nil
    do {
      _ = try await model.client.putWorkerSecret(
        accountID: context.accountID,
        scriptName: workerName,
        name: nameToSave,
        text: secretValue)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.toasts.success(
        isEditing
          ? DashL10n.string("Updated secret \(nameToSave)")
          : DashL10n.string("Added secret \(nameToSave)"))
      onSaved()
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      errorMessage = error.dashActionableMessage
    }
  }

  private func delete() async {
    guard let existingSecret, let context = model.accountRequestContext else { return }
    actionPhase = .loading
    errorMessage = nil
    do {
      try await model.client.deleteWorkerSecret(
        accountID: context.accountID,
        scriptName: workerName,
        secretName: existingSecret.name)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Deleted secret \(existingSecret.name)"))
      onDeleted?()
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      errorMessage = error.dashActionableMessage
    }
  }

  private func completePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    dismiss()
  }
}

/// Form tray for adding a new Cron Trigger expression to a Worker.
private struct WorkerCronTriggerForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss

  let workerName: String
  let existingCrons: [String]
  let allowsWrites: Bool
  let onSaved: ([WorkerCronTrigger]) -> Void

  @State private var cronText = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?

  private var normalizedCron: String {
    WorkerConfigurationRules.normalizedCronExpression(cronText)
  }

  private var isDuplicate: Bool {
    existingCrons.contains(normalizedCron)
  }

  private var isValid: Bool {
    WorkerConfigurationRules.isValidCronExpression(normalizedCron)
  }

  private var canSave: Bool {
    allowsWrites && isValid && !isDuplicate && !actionPhase.isActive
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Add trigger",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completePresentation,
      canSave: canSave,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(label: "Cron expression", text: $cronText)
            .disabled(actionPhase.isActive)

          if !normalizedCron.isEmpty {
            if isDuplicate {
              Text(DashL10n.string("This Cron Trigger already exists."))
                .dashTextStyle(.caption)
                .foregroundStyle(DashTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            } else if !isValid {
              Text(DashL10n.string("Enter a 5-field UTC cron expression, such as */5 * * * *."))
                .dashTextStyle(.caption)
                .foregroundStyle(DashTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            Text(DashL10n.ui("Presets"))
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            HStack(spacing: 8) {
              ForEach(WorkerConfigurationRules.cronPresets, id: \.cron) { preset in
                Button {
                  cronText = preset.cron
                  DashDelight.lightImpact()
                } label: {
                  Text(DashL10n.ui(preset.label))
                    .dashTextStyle(.captionSemibold)
                    .foregroundStyle(DashTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DashTheme.recessed)
                    .clipShape(Capsule())
                }
                .buttonStyle(DashPressButtonStyle())
                .disabled(actionPhase.isActive)
              }
            }
          }

          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string("Cloudflare evaluates Cron Triggers in UTC.")
    )
  }

  private func save() async {
    guard canSave, let context = model.accountRequestContext else { return }
    let nextCrons = existingCrons + [normalizedCron]
    actionPhase = .loading
    errorMessage = nil
    do {
      let updated = try await model.client.updateWorkerSchedules(
        accountID: context.accountID,
        scriptName: workerName,
        crons: nextCrons)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Added Cron Trigger"))
      onSaved(updated)
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      errorMessage = error.dashActionableMessage
    }
  }

  private func completePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    dismiss()
  }
}
