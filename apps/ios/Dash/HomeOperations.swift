import CloudflareAPI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Home operations

struct HomeDNSRecordAction: View {
  @Environment(AppModel.self) private var model
  let zones: [CloudflareZone]
  @State private var selectedZoneID: String?

  init(zones: [CloudflareZone]) {
    self.zones = zones
    _selectedZoneID = State(initialValue: zones.count == 1 ? zones.first?.id : nil)
  }

  var body: some View {
    Group {
      if let selectedZoneID {
        DNSRecordEditor(zoneID: selectedZoneID, record: nil) {
          model.featureCache.remove(FeatureCacheKey.dnsRecords(selectedZoneID))
        }
      } else if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before creating a DNS record."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
            Button {
              selectedZoneID = zone.id
            } label: {
              DashListRow(
                title: zone.name,
                subtitle: (zone.status ?? "unknown").capitalized,
                avatarSeed: zone.name
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < zones.count - 1 {
              DashListGroupDivider()
            }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the domain for the new DNS record."))
      }
    }
  }
}

struct HomeCreateKVKeyAction: View {
  @Environment(AppModel.self) private var model
  @State private var namespaces: [KVNamespace] = []
  @State private var selectedNamespaceID: String?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    Group {
      if loadedContext != model.accountRequestContext {
        HomeActionLoadingRow(title: DashL10n.string("Loading KV namespaces…"))
      } else if let selectedNamespaceID {
        KVCreateKeySheet(namespaceID: selectedNamespaceID) {
          guard let context = loadedContext, model.isCurrentAccount(context) else { return }
          model.featureCache.remove(
            prefix: "kvKeys:\(context.accountID):\(selectedNamespaceID):")
        }
      } else if loading {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Loading KV namespaces…")
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DashTheme.Spacing.listRow)
      } else if let error {
        DashNotice(kind: .error, message: error)
      } else if namespaces.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Create a KV namespace before adding a key."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(namespaces.enumerated()), id: \.element.id) { index, namespace in
            Button {
              selectedNamespaceID = namespace.id
            } label: {
              DashListRow(
                title: namespace.title,
                subtitle: DashL10n.string("KV namespace"),
                icon: SolarAsset.Content.pinList
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < namespaces.count - 1 {
              DashListGroupDivider()
            }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the namespace for the new key."))
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await loadNamespaces()
    }
  }

  private func loadNamespaces() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.kvNamespaces(context.accountID)
    if let cached: [KVNamespace] = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      apply(cached, context: context)
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listKVNamespaces(accountID: context.accountID).items
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      apply(loaded, context: context)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [KVNamespace], context: AccountRequestContext) {
    guard model.isCurrentAccount(context), loadedContext == context else { return }
    namespaces = loaded
    selectedNamespaceID = loaded.count == 1 ? loaded.first?.id : nil
    loading = false
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    namespaces = []
    selectedNamespaceID = nil
    loading = context != nil
    error = nil
  }
}

struct HomePagesDomainAction: View {
  @Environment(AppModel.self) private var model
  @State private var projects: [PagesProject] = []
  @State private var selectedProject: String?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    Group {
      if loadedContext != model.accountRequestContext {
        HomeActionLoadingRow(title: DashL10n.string("Loading Pages projects…"))
      } else if let selectedProject {
        PagesAddDomainForm(projectName: selectedProject, onAdded: {})
      } else {
        actionPicker
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
  }

  @ViewBuilder private var actionPicker: some View {
    if loading {
      HomeActionLoadingRow(title: DashL10n.string("Loading Pages projects…"))
    } else if let error {
      DashNotice(kind: .error, message: error)
    } else if projects.isEmpty {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Create a Pages project before attaching a domain."))
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
          Button {
            selectedProject = project.name
          } label: {
            DashListRow(
              title: project.name,
              subtitle: project.subdomain,
              icon: SolarAsset.Content.codeCircle
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          if index < projects.count - 1 { DashListGroupDivider() }
        }
      }
      .dashTrayDescription(DashL10n.string("Choose the Pages project for the custom domain."))
    }
  }

  private func load() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.pagesProjects(context.accountID)
    if let cached: [PagesProject] = model.featureCache.get(key) {
      apply(cached, context: context)
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listPagesProjects(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      apply(loaded, context: context)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [PagesProject], context: AccountRequestContext) {
    guard model.isCurrentAccount(context), loadedContext == context else { return }
    projects = loaded
    selectedProject = loaded.count == 1 ? loaded.first?.name : nil
    loading = false
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    projects = []
    selectedProject = nil
    loading = context != nil
    error = nil
  }
}

struct HomeWorkerDomainAction: View {
  @Environment(AppModel.self) private var model
  @State private var workers: [WorkerScript] = []
  @State private var selectedWorker: String?
  @State private var loading = true
  @State private var error: String?
  @State private var loadedContext: AccountRequestContext?

  var body: some View {
    Group {
      if loadedContext != model.accountRequestContext {
        HomeActionLoadingRow(title: DashL10n.string("Loading Workers…"))
      } else if let selectedWorker {
        WorkerAddDomainForm(service: selectedWorker, onAdded: {})
      } else {
        actionPicker
      }
    }
    .task(id: model.accountRequestContext) {
      prepareForCurrentAccount()
      await load()
    }
  }

  @ViewBuilder private var actionPicker: some View {
    if loading {
      HomeActionLoadingRow(title: DashL10n.string("Loading Workers…"))
    } else if let error {
      DashNotice(kind: .error, message: error)
    } else if workers.isEmpty {
      DashNotice(
        kind: .warning,
        message: DashL10n.string("Deploy a Worker before attaching a domain."))
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
          Button {
            selectedWorker = worker.id
          } label: {
            DashListRow(title: worker.id, icon: SolarAsset.Content.code)
          }
          .buttonStyle(DashSurfaceButtonStyle())
          if index < workers.count - 1 { DashListGroupDivider() }
        }
      }
      .dashTrayDescription(DashL10n.string("Choose the Worker for the custom domain."))
    }
  }

  private func load() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.workers(context.accountID)
    if let cached: [WorkerScript] = model.featureCache.get(key) {
      apply(cached, context: context)
      return
    }
    let client = model.client
    do {
      let loaded = try await client.listWorkers(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      apply(loaded, context: context)
    } catch {
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func apply(_ loaded: [WorkerScript], context: AccountRequestContext) {
    guard model.isCurrentAccount(context), loadedContext == context else { return }
    workers = loaded
    selectedWorker = loaded.count == 1 ? loaded.first?.id : nil
    loading = false
  }

  private func prepareForCurrentAccount() {
    let context = model.accountRequestContext
    guard loadedContext != context else { return }
    loadedContext = context
    workers = []
    selectedWorker = nil
    loading = context != nil
    error = nil
  }
}

struct HomeZoneModeAction: View {
  enum Mode {
    case development
    case underAttack

    var actionTitle: String {
      switch self {
      case .development: DashL10n.string("Enable dev mode")
      case .underAttack: DashL10n.string("Enable Under Attack")
      }
    }

    var warning: String {
      switch self {
      case .development:
        DashL10n.string(
          "Cloudflare will bypass cache for this domain and turn Development Mode off automatically after three hours."
        )
      case .underAttack:
        DashL10n.string(
          "Cloudflare will challenge every visitor. You can restore the previous security level from the domain's WAF screen."
        )
      }
    }
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let zones: [CloudflareZone]
  let mode: Mode
  @State private var selectedZoneID: String?
  @State private var actionPhase: DashActionPhase = .idle
  @State private var result: String?
  @State private var pendingResult: String?
  @State private var error: String?

  init(zones: [CloudflareZone], mode: Mode) {
    self.zones = zones
    self.mode = mode
    _selectedZoneID = State(initialValue: zones.count == 1 ? zones.first?.id : nil)
  }

  var body: some View {
    Group {
      if let zone = zones.first(where: { $0.id == selectedZoneID }) {
        DashFormSheet(
          saveTitle: result == nil ? mode.actionTitle : DashL10n.string("Done"),
          actionPhase: actionPhase,
          onSuccessPresentationCompleted: completeSuccessPresentation,
          onSave: {
            if result == nil {
              Task { await enable(for: zone) }
            } else {
              dismiss()
            }
          }
        ) {
          VStack(alignment: .leading, spacing: 14) {
            if let result {
              DashNotice(kind: .success, message: result)
            } else {
              DashNotice(kind: .warning, message: mode.warning)
              Text(zone.name)
                .dashTextStyle(.bodySemibold)
                .foregroundStyle(DashTheme.text)
            }
            if let error {
              DashNotice(kind: .error, message: error)
            }
          }
        }
      } else if zones.isEmpty {
        DashNotice(
          kind: .warning,
          message: DashL10n.string("Add a domain before changing this mode."))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
            Button {
              selectedZoneID = zone.id
            } label: {
              DashListRow(
                title: zone.name,
                subtitle: (zone.status ?? "unknown").capitalized,
                avatarSeed: zone.name
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            if index < zones.count - 1 { DashListGroupDivider() }
          }
        }
        .dashTrayDescription(DashL10n.string("Choose the domain to update."))
      }
    }
  }

  private func enable(for zone: CloudflareZone) async {
    guard let context = model.accountRequestContext else { return }
    let client = model.client
    actionPhase = .loading
    error = nil
    let op = model.optimistic.begin(.enabling)
    do {
      try await model.optimistic.waitForCommit(op)
      let successMessage: String
      switch mode {
      case .development:
        _ = try await client.updateZoneSetting(
          zoneID: zone.id, settingID: "development_mode", value: .string("on"))
        guard !Task.isCancelled, model.isCurrentAccount(context) else {
          actionPhase = .idle
          model.optimistic.finishFailure(op)
          return
        }
        successMessage = DashL10n.string("Development Mode is on for \(zone.name).")
      case .underAttack:
        _ = try await ZoneSecurityLevelOperation.setUnderAttack(
          zoneID: zone.id,
          enabled: true,
          client: client,
          isCurrent: { model.isCurrentAccount(context) })
        guard !Task.isCancelled, model.isCurrentAccount(context) else {
          actionPhase = .idle
          model.optimistic.finishFailure(op)
          return
        }
        successMessage = DashL10n.string("Under Attack mode is on for \(zone.name).")
      }
      model.featureCache.remove(FeatureCacheKey.zoneSettings(zone.id))
      pendingResult = successMessage
      model.optimistic.finishSuccess(op)
      actionPhase = .succeeded
    } catch is CancellationError {
      actionPhase = .idle
    } catch {
      actionPhase = .idle
      model.optimistic.finishFailure(op)
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func completeSuccessPresentation() {
    guard actionPhase == .succeeded, let pendingResult else { return }
    result = pendingResult
    self.pendingResult = nil
    actionPhase = .idle
  }
}

private struct HomeActionLoadingRow: View {
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .dashTextStyle(.footnote)
        .foregroundStyle(DashTheme.subtle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, DashTheme.Spacing.listRow)
  }
}

/// Starts a real upload from Home instead of merely opening the R2 catalog.
/// The last-used bucket/folder is preferred, but the destination stays explicit
/// and editable so a one-tap shortcut never writes to a surprising bucket.
private struct HomeR2UploadRequest: Sendable {
  let context: AccountRequestContext
  let bucket: String
  let prefix: String
  let fileURL: URL
  let destination: R2ShareDestination

  var key: String { prefix + fileURL.lastPathComponent }
}

struct HomeR2UploadSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let onUploaded: (String) -> Void
  @State private var buckets: [R2Bucket] = []
  @State private var selectedBucket = ""
  /// Chosen destination folder as a key prefix (trailing `/`), `""` at the
  /// bucket root. Seeded from the last-used destination, then owned by the
  /// picker — Home writes wherever the user points it, not only to the root.
  @State private var folderPrefix = ""
  /// Folders directly inside `folderPrefix`, so the picker can go deeper.
  @State private var childFolders: [String] = []
  /// A folder listing that threw. Empty and failed are different answers: a
  /// bucket with no folders offers only the root, a lookup that failed says so
  /// and leaves the chosen destination alone.
  @State private var folderListingFailed = false
  @State private var fileURL: URL?
  @State private var importsFile = false
  @State private var loading = true
  @State private var uploading = false
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var uploadedMessage: String?
  @State private var pendingUploadedMessage: String?
  @State private var uploadTask: Task<Void, Never>?
  @State private var uploadGeneration: UInt64 = 0

  /// Identity of one folder listing. The account generation is part of it, so a
  /// response can only ever land on the account, bucket, and folder that asked
  /// for it.
  private struct FolderListingRequest: Hashable {
    let context: AccountRequestContext
    let bucket: String
    let prefix: String
  }

  private var remembered: R2ShareDestination? {
    guard let accountID = model.activeAccountID else { return nil }
    return R2ShareDestination.destination(accountID: accountID)
  }

  private var folderListingRequest: FolderListingRequest? {
    guard let context = model.accountRequestContext, !selectedBucket.isEmpty else { return nil }
    return FolderListingRequest(
      context: context, bucket: selectedBucket, prefix: folderPrefix)
  }

  private var actionTitle: String {
    if uploadedMessage != nil { return DashL10n.string("Done") }
    if fileURL == nil { return DashL10n.string("Choose file") }
    return DashL10n.string("Upload")
  }

  var body: some View {
    DashFormSheet(
      saveTitle: actionTitle,
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeUploadPresentation,
      canSave: uploadedMessage != nil || (!loading && !selectedBucket.isEmpty),
      onSave: performPrimaryAction
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if let uploadedMessage {
          DashNotice(kind: .success, message: uploadedMessage)
        } else {
          if let error {
            DashNotice(kind: .error, message: error)
          }

          if loading {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
              Text("Loading R2 buckets…")
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DashTheme.Spacing.listRow)
          } else if buckets.isEmpty {
            DashNotice(
              kind: .warning,
              message: DashL10n.string("Create an R2 bucket before uploading a file."))
          } else {
            DashFormMenuField(
              label: DashL10n.string("Bucket"),
              selection: $selectedBucket,
              options: buckets.map(\.name)
            )

            HomeR2FolderField(prefix: $folderPrefix, childFolders: childFolders)

            if folderListingFailed {
              DashNotice(
                kind: .warning,
                message: DashL10n.string(
                  "Can't list this bucket's folders. The upload still goes to the folder shown above."
                ))
            }

            if let fileURL {
              HStack(spacing: 12) {
                SolarIcon(asset: SolarAsset.Content.cloud, size: 22, color: DashTheme.brand)
                VStack(alignment: .leading, spacing: 2) {
                  Text(fileURL.lastPathComponent)
                    .dashTextStyle(.bodyMedium)
                    .foregroundStyle(DashTheme.text)
                    .lineLimit(1)
                  // Where the file lands, spelled out: bucket, chosen folder,
                  // and the key the upload will write.
                  Text(selectedBucket + "/" + folderPrefix + fileURL.lastPathComponent)
                    .dashTextStyle(.footnote)
                    .foregroundStyle(DashTheme.subtle)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(DashL10n.string("Change")) { importsFile = true }
                  .dashTextStyle(.supportingMedium)
                  .foregroundStyle(DashTheme.brand)
                  .buttonStyle(DashPressButtonStyle())
              }
              .padding(14)
              .background(
                DashTheme.recessed,
                in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous)
              )
            }
          }
        }
      }
      .disabled(uploading)
    }
    .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data]) { result in
      guard !uploading else { return }
      switch result {
      case .success(let url):
        fileURL = url
        error = nil
      case .failure(let error):
        self.error = error.dashActionableMessage
      }
    }
    .task { await loadBuckets() }
    // Restarts on every bucket or folder hop, and cancels the one it replaces.
    .task(id: folderListingRequest) { await loadChildFolders() }
    .onChange(of: selectedBucket) { _, bucket in
      folderPrefix = rememberedPrefix(inBucket: bucket)
    }
    .onDisappear { cancelUpload() }
  }

  private func performPrimaryAction() {
    if uploadedMessage != nil {
      dismiss()
    } else if fileURL == nil {
      importsFile = true
    } else {
      startUpload()
    }
  }

  private func loadBuckets() async {
    guard let context = model.accountRequestContext else {
      loading = false
      return
    }
    let key = FeatureCacheKey.r2Buckets(context.accountID)
    if let cached: [R2Bucket] = model.featureCache.get(key) {
      guard model.isCurrentAccount(context) else { return }
      applyBuckets(cached)
      return
    }
    do {
      let loaded = try await model.client.listR2Buckets(accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      model.featureCache.set(key, loaded)
      applyBuckets(loaded)
    } catch {
      guard !Task.isCancelled, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
      loading = false
    }
  }

  private func applyBuckets(_ loaded: [R2Bucket]) {
    buckets = loaded
    selectedBucket =
      loaded.first(where: { $0.name == remembered?.bucket })?.name
      ?? loaded.first?.name ?? ""
    folderPrefix = rememberedPrefix(inBucket: selectedBucket)
    loading = false
  }

  /// The last-used folder counts only inside the bucket it was used in; every
  /// other bucket starts at its root.
  private func rememberedPrefix(inBucket bucket: String) -> String {
    guard let remembered, remembered.bucket == bucket else { return "" }
    return R2FolderPath.normalized(remembered.prefix)
  }

  /// Lists the folders one level under the chosen destination. Reads and writes
  /// the same per-prefix listing cache as the R2 browser, so hopping between
  /// Home and a bucket screen does not re-fetch what the other just loaded.
  private func loadChildFolders() async {
    guard let request = folderListingRequest else {
      childFolders = []
      folderListingFailed = false
      return
    }
    let key = FeatureCacheKey.r2Objects(
      accountID: request.context.accountID, bucket: request.bucket, prefix: request.prefix)
    if let cached: R2BrowserSnapshot = model.featureCache.get(key) {
      childFolders = cached.commonPrefixes
      folderListingFailed = false
      return
    }
    childFolders = []
    folderListingFailed = false
    do {
      let page = try await model.client.listR2Objects(
        accountID: request.context.accountID,
        bucket: request.bucket,
        prefix: request.prefix.isEmpty ? nil : request.prefix,
        delimiter: "/")
      guard !Task.isCancelled, folderListingRequest == request else { return }
      childFolders = page.commonPrefixes
      let objects = page.objects.filter { !R2FolderMarker.isMarker(key: $0.key) }
      let hasFolderMarker =
        !request.prefix.isEmpty && page.objects.contains { $0.key == request.prefix }
      model.featureCache.set(
        key,
        R2BrowserSnapshot(
          objects: objects, commonPrefixes: page.commonPrefixes, cursor: page.cursor,
          hasFolderMarker: hasFolderMarker))
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation, folderListingRequest == request
      else { return }
      folderListingFailed = true
    }
  }

  private func startUpload() {
    guard let context = model.accountRequestContext,
      let fileURL,
      !selectedBucket.isEmpty
    else { return }
    let bucket = selectedBucket
    let prefix = folderPrefix
    let rememberedDestination = R2ShareDestination.destination(accountID: context.accountID)
    let destination = R2ShareDestination(
      accountID: context.accountID,
      bucket: bucket,
      prefix: prefix,
      publicHost: rememberedDestination?.bucket == bucket
        ? rememberedDestination?.publicHost ?? ""
        : ""
    )
    let request = HomeR2UploadRequest(
      context: context,
      bucket: bucket,
      prefix: prefix,
      fileURL: fileURL,
      destination: destination)

    uploadTask?.cancel()
    uploadGeneration &+= 1
    let generation = uploadGeneration
    uploading = true
    actionPhase = .loading
    error = nil
    pendingUploadedMessage = nil
    uploadTask = Task { await upload(request, generation: generation) }
  }

  private func upload(_ request: HomeR2UploadRequest, generation: UInt64) async {
    defer { finishUpload(generation: generation) }
    do {
      guard isCurrentUpload(generation, context: request.context) else { return }
      let access = request.fileURL.startAccessingSecurityScopedResource()
      defer {
        if access {
          request.fileURL.stopAccessingSecurityScopedResource()
        }
      }
      guard
        let size = try? request.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
      else {
        throw HomeR2UploadError.unreadableFile
      }
      guard size <= R2Media.transferSizeLimit else {
        throw HomeR2UploadError.fileTooLarge(request.fileURL.lastPathComponent, size)
      }
      try Task.checkCancellation()
      try await model.client.putR2Object(
        accountID: request.context.accountID,
        bucket: request.bucket,
        key: request.key,
        fileURL: request.fileURL,
        contentType: UTType(filenameExtension: request.fileURL.pathExtension)?.preferredMIMEType
      )
      guard isCurrentUpload(generation, context: request.context) else { return }
      model.featureCache.remove(
        prefix: FeatureCacheKey.r2ObjectsPrefix(
          accountID: request.context.accountID,
          bucket: request.bucket))
      let domains: R2DomainsSnapshot? = model.featureCache.get(
        FeatureCacheKey.r2Domains(
          accountID: request.context.accountID,
          bucket: request.bucket))
      var destination = request.destination
      destination.publicHost = domains?.publicHost ?? destination.publicHost
      R2ShareDestination.record(destination)
      onUploaded(request.bucket)
      let message = DashL10n.string(
        "Uploaded \(request.fileURL.lastPathComponent) to \(request.bucket)")
      pendingUploadedMessage = message
      model.toasts.success(message)
      actionPhase = .succeeded
    } catch {
      guard isCurrentUpload(generation, context: request.context) else { return }
      actionPhase = .idle
      self.error = error.dashActionableMessage
      DashDelight.failError()
    }
  }

  private func isCurrentUpload(
    _ generation: UInt64,
    context: AccountRequestContext
  ) -> Bool {
    !Task.isCancelled
      && uploadGeneration == generation
      && model.isCurrentAccount(context)
  }

  private func finishUpload(generation: UInt64) {
    guard uploadGeneration == generation else { return }
    uploadTask = nil
    if actionPhase != .succeeded {
      uploading = false
      actionPhase = .idle
    }
  }

  private func completeUploadPresentation() {
    guard actionPhase == .succeeded, let pendingUploadedMessage else { return }
    uploadedMessage = pendingUploadedMessage
    self.pendingUploadedMessage = nil
    uploading = false
    actionPhase = .idle
  }

  private func cancelUpload() {
    uploadGeneration &+= 1
    uploadTask?.cancel()
    uploadTask = nil
    uploading = false
    pendingUploadedMessage = nil
    actionPhase = .idle
  }
}

/// Destination-folder chooser for an R2 upload. Wears `DashFormMenuField`'s
/// chrome, but folder names are bucket data — they render verbatim instead of
/// going through `DashL10n.ui`, which would translate a folder that happens to
/// share a catalog key. One menu reaches any depth: it lists the bucket root,
/// the path down to the current choice, and the folders inside it, so choosing
/// a folder both selects it and offers its children on the next open. There is
/// no ring while the next level loads — a menu value is never replaced by
/// progress; the list simply grows when the listing lands.
private struct HomeR2FolderField: View {
  @Binding var prefix: String
  let childFolders: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Folder")
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker("Folder", selection: $prefix) {
          Text("Bucket root").tag("")
          ForEach(
            R2FolderPath.destinations(prefix: prefix, children: childFolders), id: \.self
          ) { folder in
            Text(R2FolderPath.label(for: folder)).tag(folder)
          }
        }
      } label: {
        HStack(spacing: 8) {
          Group {
            if prefix.isEmpty {
              Text("Bucket root")
            } else {
              Text(R2FolderPath.label(for: prefix))
            }
          }
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(DashTheme.text)
          .lineLimit(1)
          // A deep path matters at its tail — keep the chosen folder visible.
          .truncationMode(.head)
          Spacer(minLength: 0)
          SolarIcon(
            asset: SolarAsset.chevronRight, size: DashTheme.Chevron.compact,
            color: DashTheme.placeholder
          )
          .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      }
    }
  }
}

private enum HomeR2UploadError: LocalizedError {
  case unreadableFile
  case fileTooLarge(String, Int)

  var errorDescription: String? {
    switch self {
    case .unreadableFile:
      DashL10n.string("Can't read that file's size")
    case .fileTooLarge(let name, let size):
      R2UploadTooLargeCopy.message(
        fileName: name,
        size: size,
        guidance: .dashLimitOnly)
    }
  }
}

/// Two-phase add-domain tray: the form morphs into the assigned name servers
/// once Cloudflare accepts the zone, because the registrar update is the step
/// people forget.
/// Shared with the Domains catalog empty state, which offers the same flow
/// so a zero-domain account isn't a dead end there.
struct AddDomainSheet: View {
  private enum Route: Hashable, Sendable {
    case form
    case created(String)
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let onCreated: () -> Void
  @State private var name = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var error: String?
  @State private var created: CloudflareZone?
  @State private var pendingCreated: CloudflareZone?

  private var route: Route {
    created.map { .created($0.id) } ?? .form
  }

  var body: some View {
    DashFormSheet(
      saveTitle: created == nil ? "Add domain" : "Done",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeCreatePresentation,
      canSave: created != nil || AddDomainValidation.isPlausibleZoneName(name),
      onSave: {
        if created == nil {
          Task { await create() }
        } else {
          dismiss()
        }
      }
    ) {
      DashTrayFlow(
        route: route,
        role: created == nil ? .root : .detail
      ) { _ in
        if let created {
          successContent(created)
        } else {
          formContent
        }
      }
    }
    .dashTrayTitle(
      created == nil ? DashL10n.string("Add domain") : DashL10n.string("Domain added")
    )
    // Step two answers the question itself, in the success content.
    .dashTrayDescription(
      created == nil
        ? (model.isDemoSession
          ? DashL10n.string(
            "Adds a sample domain that is ready to edit. No registrar or DNS changes are needed.")
          : DashL10n.string(
            "Cloudflare assigns name servers next; the domain activates once your registrar points at them."
          ))
        : nil)
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let error {
        DashNotice(kind: .error, message: error)
      }
      DashFormField(
        label: "Domain",
        text: $name,
        keyboard: .URL,
        contentType: .URL)
    }
  }

  private func successContent(_ zone: CloudflareZone) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.isDemoSession {
        DashNotice(
          kind: .success,
          message: "Domain added to the demo. DNS records and settings are ready to try.")
      } else {
        // Localize WITH the argument, not after it: DashNotice runs `message`
        // through DashL10n.ui, and by then the zone name is already spliced in, so
        // the catalog's "%@ is on Cloudflare." could never match.
        DashNotice(kind: .success, message: DashL10n.string("\(zone.name) is on Cloudflare."))
        if let servers = zone.nameServers, !servers.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Point the domain's name servers at")
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.subtle)
            ForEach(servers, id: \.self) { server in
              Text(server)
                .dashTextStyle(.code)
                .foregroundStyle(DashTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                  DashTheme.recessed,
                  in: RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
            }
          }
        }
        Text("It shows as Pending until the name servers update — usually within a few hours.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func create() async {
    guard let context = model.accountRequestContext else { return }
    let client = model.client
    let normalizedName = AddDomainValidation.normalized(name)
    actionPhase = .loading
    error = nil
    do {
      let zone = try await client.createZone(
        name: normalizedName, accountID: context.accountID)
      guard !Task.isCancelled, model.isCurrentAccount(context) else {
        actionPhase = .idle
        return
      }
      model.toasts.success(DashL10n.string("Created successfully"))
      onCreated()
      pendingCreated = zone
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard !error.dashIsCancellation, model.isCurrentAccount(context) else { return }
      self.error = error.dashActionableMessage
    }
  }

  private func completeCreatePresentation() {
    guard actionPhase == .succeeded, let pendingCreated else { return }
    created = pendingCreated
    self.pendingCreated = nil
    actionPhase = .idle
  }
}
