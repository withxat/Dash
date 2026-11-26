import CloudflareAPI
import SwiftUI
import UIKit

/// Pure helpers for Pages project environment variables and deployment filters.
enum PagesConfigurationRules {
  static func normalizedVariableName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func isValidVariableName(_ raw: String) -> Bool {
    let name = normalizedVariableName(raw)
    guard let first = name.first else { return false }
    guard first.isASCII, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
  }

  static func sortedVariables(
    from project: PagesProject,
    environment: PagesEnvironment
  ) -> [PagesNamedEnvVar] {
    let vars = project.deploymentConfigs?.config(for: environment)?.envVars ?? [:]
    return
      vars
      .map { PagesNamedEnvVar(name: $0.key, variable: $0.value) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

struct PagesNamedEnvVar: Identifiable, Hashable, Sendable {
  var id: String { name }
  let name: String
  let variable: PagesEnvVar
}

/// Pages project build configuration, connected repository, and Production /
/// Preview environment variables. Uses existing `page.read` / `page.write`.
struct PagesConfigurationView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let projectName: String

  @State private var project: PagesProject?
  @State private var loading = true
  @State private var hasPresentedContent = false
  @State private var error: String?
  @State private var environment: PagesEnvironment = .production
  @State private var selectedVariable: PagesNamedEnvVar?
  @State private var showsAddVariable = false
  @State private var loadedContext: AccountRequestContext?

  private var requiredWriteScopes: Set<String> {
    writeScopes(for: .pagesConfiguration(projectName))
  }

  private var allowsWrites: Bool {
    featureAllowsWrites && model.hasScopes(requiredWriteScopes)
  }

  private var activeConfig: PagesDeploymentConfig? {
    project?.deploymentConfigs?.config(for: environment)
  }

  private var activeVariables: [PagesNamedEnvVar] {
    guard let project else { return [] }
    return PagesConfigurationRules.sortedVariables(from: project, environment: environment)
  }

  private var hasBuildOrSourceDetails: Bool {
    guard let project else { return false }
    let hasSource =
      project.source?.config?.owner != nil
      || project.source?.config?.repoName != nil
      || project.productionBranch != nil
      || project.source?.config?.productionBranch != nil
    let hasBuild =
      project.buildConfig?.buildCommand != nil
      || project.buildConfig?.destinationDirectory != nil
      || project.buildConfig?.rootDirectory != nil
    return hasSource || hasBuild
  }

  private var hasRuntimeDetails: Bool {
    guard let activeConfig else { return false }
    return activeConfig.compatibilityDate != nil || !activeConfig.compatibilityFlags.isEmpty
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
      title: "Settings & variables",
      tint: FeatureVisualIdentity.heroColor(for: .pages)
    )
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
    .dashTray(
      item: $selectedVariable,
      title: { $0.name },
      tone: FeatureVisualIdentity.tone(for: .pages),
      content: { entry in
        variableTrayContent(entry)
      }
    )
    .dashTray(
      isPresented: $showsAddVariable,
      title: "Add variable",
      tone: FeatureVisualIdentity.tone(for: .pages)
    ) {
      PagesEnvVarForm(
        projectName: projectName,
        environment: environment,
        existing: nil,
        allowsWrites: allowsWrites,
        onSaved: { updated in
          applyUpdatedProject(updated)
        }
      )
    }
  }

  @ViewBuilder
  private func configurationBody(mode: DashBodyMode) -> some View {
    if !mode.isPlaceholder, !allowsWrites {
      FeatureWriteAccessNotice(
        message: "Read-only — grant Pages write access to edit environment variables.",
        scopes: requiredWriteScopes
      )
      .dashBodySlot(reduceMotion: reduceMotion)
    }

    if mode.isPlaceholder || hasBuildOrSourceDetails {
      buildAndSourceSection(mode: mode)
        .dashSectionBoundary(!mode.isPlaceholder && !allowsWrites)
        .dashBodySlot(reduceMotion: reduceMotion)
    }

    if !mode.isPlaceholder {
      DashTextTabs(
        items: [
          (DashL10n.string("Production"), PagesEnvironment.production),
          (DashL10n.string("Preview"), PagesEnvironment.preview),
        ],
        selection: $environment
      )
      .dashSectionBoundary(hasBuildOrSourceDetails || !allowsWrites)
      .dashBodySlot(reduceMotion: reduceMotion)
    }

    if !mode.isPlaceholder, hasRuntimeDetails, let activeConfig {
      DashTwoToneListGroup(title: "Runtime") {
        if let compatibilityDate = activeConfig.compatibilityDate {
          DashValueCard(title: "Compatibility date", value: compatibilityDate)
        }
        if !activeConfig.compatibilityFlags.isEmpty {
          DashValueCard(
            title: "Compatibility flags",
            value: activeConfig.compatibilityFlags.joined(separator: ", "))
        }
      }
      .dashSectionBoundary()
      .dashBodySlot(reduceMotion: reduceMotion)
    }

    variablesSection(mode: mode)
  }

  @ViewBuilder
  private func buildAndSourceSection(mode: DashBodyMode) -> some View {
    DashTwoToneListGroup(title: "Build & source") {
      if mode.isPlaceholder {
        DashToggleRowPlaceholder()
        DashToggleRowPlaceholder()
        DashToggleRowPlaceholder()
      } else if let project {
        if let repo = Self.repositoryText(for: project) {
          DashValueCard(title: "Repository", value: repo)
        }
        if let branch = project.productionBranch ?? project.source?.config?.productionBranch {
          DashValueCard(title: "Production branch", value: branch)
        }
        if let buildCommand = project.buildConfig?.buildCommand {
          DashValueCard(title: "Build command", value: buildCommand)
        }
        if let outputDir = project.buildConfig?.destinationDirectory {
          DashValueCard(title: "Output directory", value: outputDir)
        }
        if let rootDir = project.buildConfig?.rootDirectory {
          DashValueCard(title: "Root directory", value: rootDir)
        }
      }
    }
  }

  @ViewBuilder
  private func variablesSection(mode: DashBodyMode) -> some View {
    DashListGroupHeader(
      title: DashL10n.ui("Environment variables"),
      actionTitle: !mode.isPlaceholder && allowsWrites ? DashL10n.ui("Add") : nil,
      actionIcon: !mode.isPlaceholder && allowsWrites ? SolarAsset.plus : nil,
      action: !mode.isPlaceholder && allowsWrites ? { showsAddVariable = true } : nil
    )
    .dashTwoToneHeaderBand()
    .dashSectionBoundary()
    .dashBodySlot(reduceMotion: reduceMotion)

    if mode.isPlaceholder || !activeVariables.isEmpty {
      dashModeListRows(
        mode: mode,
        items: activeVariables,
        placeholderRows: 2,
        reduceMotion: reduceMotion,
        frame: .twoTone
      ) { entry in
        Button {
          selectedVariable = entry
        } label: {
          DashListRow(
            title: entry.name,
            subtitle: entry.variable.isSecret
              ? DashL10n.ui("Encrypted secret")
              : (entry.variable.value ?? ""),
            icon: entry.variable.isSecret ? SolarAsset.Content.lock : SolarAsset.Content.slider,
            showsChevron: false
          )
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("pages-env-\(environment.rawValue)-\(entry.name)")
      }
    } else {
      Text("No environment variables configured.")
        .dashTwoToneNote()
        .dashTwoToneRowSlice()
        .dashBodySlot(reduceMotion: reduceMotion)
    }
  }

  @ViewBuilder
  private func variableTrayContent(_ entry: PagesNamedEnvVar) -> some View {
    if allowsWrites {
      PagesEnvVarForm(
        projectName: projectName,
        environment: environment,
        existing: entry,
        allowsWrites: allowsWrites,
        onSaved: { updated in
          applyUpdatedProject(updated)
        }
      )
    } else {
      DashDetailTray(
        fields: [
          DashDetailField(label: "Name", value: entry.name, mono: true),
          DashDetailField(
            label: "Type",
            value: DashL10n.ui(
              entry.variable.isSecret ? "Encrypted secret" : "Environment variable")
          ),
          entry.variable.value.map { DashDetailField(label: "Value", value: $0, mono: true) },
        ].compactMap { $0 },
        accessory: {
          if let value = entry.variable.value, !entry.variable.isSecret {
            DashActionButton(title: "Copy value") {
              UIPasteboard.general.string = value
              DashDelight.lightImpact()
              model.toasts.success(DashL10n.string("Value copied"))
            }
          }
        }
      )
    }
  }

  private static func repositoryText(for project: PagesProject) -> String? {
    guard let config = project.source?.config else { return nil }
    switch (config.owner, config.repoName) {
    case (let owner?, let repo?): return "\(owner)/\(repo)"
    case (nil, let repo?): return repo
    default: return nil
    }
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    project = nil
    loading = context != nil
    hasPresentedContent = false
    error = nil
    selectedVariable = nil
    showsAddVariable = false
  }

  private func applyUpdatedProject(_ updated: PagesProject) {
    project = updated
    if let accountID = model.activeAccountID {
      model.featureCache.set(
        FeatureCacheKey.pagesProject(accountID: accountID, name: projectName), updated)
    }
  }

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.pagesProject(accountID: context.accountID, name: projectName)
    if !force, let cached: PagesProject = model.featureCache.get(key),
      cached.deploymentConfigs != nil || cached.buildConfig != nil || cached.source != nil
    {
      project = cached
      hasPresentedContent = true
      loading = false
      error = nil
      return
    }
    if !hasPresentedContent { loading = true }
    error = nil
    do {
      let fetched = try await model.client.getPagesProject(
        accountID: context.accountID, projectName: projectName)
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      project = fetched
      hasPresentedContent = true
      error = nil
      model.featureCache.set(key, fetched)
    } catch {
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

private struct PagesEnvVarForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss

  let projectName: String
  let environment: PagesEnvironment
  let existing: PagesNamedEnvVar?
  let allowsWrites: Bool
  let onSaved: (PagesProject) -> Void

  @State private var name: String
  @State private var value: String
  @State private var isSecret: Bool
  @State private var revealSecret = false
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?

  init(
    projectName: String,
    environment: PagesEnvironment,
    existing: PagesNamedEnvVar?,
    allowsWrites: Bool,
    onSaved: @escaping (PagesProject) -> Void
  ) {
    self.projectName = projectName
    self.environment = environment
    self.existing = existing
    self.allowsWrites = allowsWrites
    self.onSaved = onSaved
    _name = State(initialValue: existing?.name ?? "")
    _value = State(
      initialValue: existing?.variable.isSecret == true ? "" : (existing?.variable.value ?? ""))
    _isSecret = State(initialValue: existing?.variable.isSecret ?? false)
  }

  private var isEditing: Bool { existing != nil }

  private var normalizedName: String {
    PagesConfigurationRules.normalizedVariableName(name)
  }

  private var canSave: Bool {
    allowsWrites
      && PagesConfigurationRules.isValidVariableName(normalizedName)
      && !value.isEmpty
      && !actionPhase.isActive
  }

  private var environmentTitle: String {
    environment == .production
      ? DashL10n.string("Production")
      : DashL10n.string("Preview")
  }

  var body: some View {
    DashFormSheet(
      saveTitle: isEditing ? "Save" : "Add variable",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completePresentation,
      canSave: canSave,
      deleteMessage: isEditing && allowsWrites
        ? DashL10n.string(
          "Remove \(normalizedName) from \(environmentTitle) environment variables?")
        : nil,
      deleteError: errorMessage,
      onDelete: isEditing && allowsWrites ? { Task { await delete() } } : nil,
      secondaryActionTitle: (isEditing && !isSecret && !(existing?.variable.value ?? "").isEmpty)
        ? "Copy value" : nil,
      onSecondaryAction: (isEditing && !isSecret && !(existing?.variable.value ?? "").isEmpty)
        ? {
          if let currentValue = existing?.variable.value {
            UIPasteboard.general.string = currentValue
            DashDelight.lightImpact()
            model.toasts.success(DashL10n.string("Value copied"))
          }
        } : nil,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(label: "Name", text: $name)
            .disabled(isEditing || actionPhase.isActive)

          if !isEditing, !normalizedName.isEmpty,
            !PagesConfigurationRules.isValidVariableName(normalizedName)
          {
            Text(DashL10n.string("Use ASCII letters, numbers, and underscores only."))
              .dashTextStyle(.caption)
              .foregroundStyle(DashTheme.danger)
              .fixedSize(horizontal: false, vertical: true)
          }

          if isSecret {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(DashL10n.ui(isEditing ? "New value" : "Value"))
                  .dashTextStyle(.footnoteSemibold)
                  .foregroundStyle(DashTheme.subtle)
                Spacer()
                Button(DashL10n.string(revealSecret ? "Hide" : "Show")) {
                  revealSecret.toggle()
                }
                .dashTextStyle(.captionSemibold)
                .foregroundStyle(DashTheme.subtle)
                .buttonStyle(DashPressButtonStyle())
              }
              Group {
                if revealSecret {
                  TextField(DashL10n.ui("Secret value"), text: $value)
                } else {
                  SecureField(DashL10n.ui("Secret value"), text: $value)
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
              .clipShape(
                RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
            }
          } else {
            DashFormField(label: "Value", text: $value)
              .disabled(actionPhase.isActive)
          }

          if !isEditing {
            DashToggleRow(
              title: "Encrypt value",
              subtitle: "Encrypted secrets cannot be viewed again after saving.",
              isOn: $isSecret,
              isEnabled: !actionPhase.isActive
            )
          }

          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string("Changes apply to new \(environmentTitle) deployments.")
    )
  }

  private func save() async {
    guard canSave, let context = model.accountRequestContext else { return }
    let key = normalizedName
    actionPhase = .loading
    errorMessage = nil
    do {
      let updated = try await model.client.updatePagesEnvironmentVariable(
        accountID: context.accountID,
        projectName: projectName,
        environment: environment,
        name: key,
        value: value,
        isSecret: isSecret)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.toasts.success(
        isEditing
          ? DashL10n.string("Updated variable \(key)")
          : DashL10n.string("Added variable \(key)"))
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

  private func delete() async {
    guard let existing, let context = model.accountRequestContext else { return }
    actionPhase = .loading
    errorMessage = nil
    do {
      let updated = try await model.client.deletePagesEnvironmentVariable(
        accountID: context.accountID,
        projectName: projectName,
        environment: environment,
        name: existing.name)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Deleted variable \(existing.name)"))
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
