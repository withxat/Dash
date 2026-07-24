import CloudflareAPI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Payload of one shared item. The provider-owned URL is copied into an
/// extension-owned staging directory while its completion handler is active.
struct ShareAttachment: Identifiable, Sendable {
  let id = UUID()
  let filename: String
  let fileURL: URL
  let size: Int64
  let contentType: String?
}

/// Share-sheet entry point: hosts the SwiftUI flow and hands the extension
/// context's lifecycle callbacks to the model.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    ShareUploadModel.removeStaleStagingDirectories(olderThan: 60 * 60)
    guard let context = extensionContext else { return }
    let model = ShareUploadModel(
      finish: { context.completeRequest(returningItems: nil) },
      cancel: { context.cancelRequest(withError: CocoaError(.userCancelled)) },
      openSettings: {
        guard let url = URL(string: "dash://settings") else { return }
        context.open(url, completionHandler: nil)
      })
    let host = UIHostingController(rootView: ShareUploadView(model: model))
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
    let providers = context.inputItems
      .compactMap { $0 as? NSExtensionItem }
      .flatMap { $0.attachments ?? [] }
    model.startPreparing(providers: providers)
  }
}

@MainActor
@Observable
final class ShareUploadModel {
  enum Phase: Equatable {
    case loading
    case signedOut
    case authorizationRequired
    case ready
    case uploading(Int, Int)
    case done
    case failed(String)
  }

  /// Keep individual shares short and reject oversized batches before any
  /// network work. Bodies stay file-backed throughout the extension.
  nonisolated static let perItemSizeLimit: Int64 = 50 * 1024 * 1024
  nonisolated static let totalSizeLimit: Int64 = 100 * 1024 * 1024
  nonisolated static let stagingChunkSize = 64 * 1024

  nonisolated private static var stagingRoot: URL {
    FileManager.default.temporaryDirectory
      .appending(path: "dash-share", directoryHint: .isDirectory)
  }

  var attachments: [ShareAttachment] = []
  var buckets: [R2Bucket] = []
  var bucket = ""
  var prefix = ""
  var phase: Phase = .loading
  var copiedURL: URL?
  var accountName = ""

  var accountLabel: String {
    guard let accountID else { return "Cloudflare account" }
    let suffix = String(accountID.suffix(8))
    return accountName.isEmpty ? "Account …\(suffix)" : "\(accountName) · …\(suffix)"
  }

  private let tokenStore = KeychainTokenStore()
  private let client: CloudflareClient
  private let finishRequest: () -> Void
  private let cancelRequest: () -> Void
  private let openSettingsRequest: () -> Void
  private var accountID: String?
  private var stagingDirectory: URL?
  private var prepareTask: Task<Void, Never>?
  private var uploadTask: Task<Void, Never>?
  private var requestEnded = false

  init(
    finish: @escaping () -> Void,
    cancel: @escaping () -> Void,
    openSettings: @escaping () -> Void
  ) {
    finishRequest = finish
    cancelRequest = cancel
    openSettingsRequest = openSettings
    client = CloudflareClient(
      clientID: AppConfiguration.current.clientID, tokenStore: tokenStore,
      session: DashAPISession.shared)
  }

  func startPreparing(providers: [NSItemProvider]) {
    prepareTask?.cancel()
    prepareTask = Task { [weak self] in
      await self?.prepare(providers: providers)
    }
  }

  func prepare(providers: [NSItemProvider]) async {
    let token = (try? await tokenStore.getAccessToken()) ?? nil
    guard !Task.isCancelled, !requestEnded else { return }
    // Only the client id matters here — the extension never runs the OAuth
    // authorize flow, so `isConfigured`'s redirect-URI requirement (absent
    // from this bundle's Info.plist) must not gate it.
    let clientID = AppConfiguration.current.clientID
    guard !clientID.isEmpty, !clientID.contains("$("), token != nil,
      let accountID = R2ShareDestination.activeAccountID()
    else {
      phase = .signedOut
      return
    }
    self.accountID = accountID
    guard await hasR2WriteAccess() else {
      phase = .authorizationRequired
      return
    }
    if let destination = R2ShareDestination.destination(accountID: accountID) {
      bucket = destination.bucket
      prefix = destination.prefix
    }
    guard let stagingDirectory = Self.makeStagingDirectory() else {
      phase = .failed("Dash couldn't prepare the shared files.")
      return
    }
    self.stagingDirectory = stagingDirectory
    let loaded = await Self.load(
      providers: providers,
      stagingDirectory: stagingDirectory)
    guard !Task.isCancelled, !requestEnded else {
      cleanupStaging()
      return
    }
    attachments = loaded.attachments
    if let oversizedName = loaded.oversizedNames.first {
      cleanupStaging()
      phase = .failed(
        "\(oversizedName) is over the 50 MB share-sheet limit. Upload it from Dash instead.")
      return
    }
    if loaded.exceedsTotalLimit {
      cleanupStaging()
      phase = .failed(
        "This batch is over the 100 MB share-sheet limit. Share fewer images at a time.")
      return
    }
    if attachments.isEmpty {
      cleanupStaging()
      phase = .failed("Nothing Dash can upload was shared.")
      return
    }
    accountName =
      (try? await client.listAccounts())?
      .first(where: { $0.id == accountID })?.name ?? ""
    // The picker degrades to a read-only label when this fails (offline) —
    // the remembered bucket still works.
    buckets = (try? await client.listR2Buckets(accountID: accountID)) ?? []
    guard !Task.isCancelled, !requestEnded else {
      cleanupStaging()
      return
    }
    guard R2ShareDestination.isActiveAccount(accountID) else {
      cleanupStaging()
      phase = .failed(
        "The active Cloudflare account changed while this sheet was open. Close it and share again."
      )
      return
    }
    if bucket.isEmpty { bucket = buckets.first?.name ?? "" }
    if bucket.isEmpty {
      cleanupStaging()
      phase = .failed("No R2 buckets found in this account.")
    } else {
      phase = .ready
    }
  }

  func finish() {
    guard !requestEnded else { return }
    requestEnded = true
    prepareTask?.cancel()
    uploadTask?.cancel()
    cleanupStaging()
    finishRequest()
  }

  func cancel() {
    guard !requestEnded else { return }
    requestEnded = true
    prepareTask?.cancel()
    uploadTask?.cancel()
    cleanupStaging()
    cancelRequest()
  }

  func openWriteAccessSettings() {
    guard !requestEnded else { return }
    openSettingsRequest()
  }

  func startUpload() {
    uploadTask?.cancel()
    uploadTask = Task { [weak self] in
      await self?.upload()
    }
  }

  var normalizedPrefix: String {
    var value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("/") { value.removeFirst() }
    if !value.isEmpty && !value.hasSuffix("/") { value += "/" }
    return value
  }

  func upload() async {
    guard !requestEnded, let accountID, !bucket.isEmpty else { return }
    guard await hasR2WriteAccess() else {
      cleanupStaging()
      phase = .authorizationRequired
      return
    }
    guard R2ShareDestination.isActiveAccount(accountID) else {
      stopForAccountChange(uploadedCount: 0)
      return
    }
    let destinationBucket = bucket
    let cleanPrefix = normalizedPrefix
    let uploadAttachments = attachments
    var lastKey: String?
    var uploadedCount = 0
    // Camera batches repeat filenames; a duplicate key would overwrite the
    // object uploaded seconds earlier.
    var usedKeys = Set<String>()
    for (index, item) in uploadAttachments.enumerated() {
      guard !Task.isCancelled, !requestEnded else {
        cleanupStaging()
        return
      }
      guard R2ShareDestination.isActiveAccount(accountID) else {
        stopForAccountChange(uploadedCount: uploadedCount)
        return
      }
      phase = .uploading(index + 1, uploadAttachments.count)
      guard item.size <= Self.perItemSizeLimit else {
        cleanupStaging()
        phase = .failed(
          "\(item.filename) is over the 50 MB share-sheet limit. Upload it from Dash instead.")
        return
      }
      var key = cleanPrefix + item.filename
      if !usedKeys.insert(key).inserted {
        let base = (item.filename as NSString).deletingPathExtension
        let ext = (item.filename as NSString).pathExtension
        var counter = 2
        repeat {
          key = cleanPrefix + base + "-\(counter)" + (ext.isEmpty ? "" : ".\(ext)")
          counter += 1
        } while !usedKeys.insert(key).inserted
      }
      do {
        try await client.putR2Object(
          accountID: accountID, bucket: destinationBucket, key: key, fileURL: item.fileURL,
          contentType: item.contentType)
        guard !Task.isCancelled, !requestEnded else {
          cleanupStaging()
          return
        }
        uploadedCount += 1
        guard R2ShareDestination.isActiveAccount(accountID) else {
          stopForAccountChange(uploadedCount: uploadedCount)
          return
        }
        lastKey = key
      } catch {
        cleanupStaging()
        guard !Task.isCancelled, !requestEnded else { return }
        phase = .failed(error.localizedDescription)
        return
      }
    }
    let host = await resolvePublicHost(accountID: accountID, bucket: destinationBucket)
    guard !Task.isCancelled, !requestEnded else {
      cleanupStaging()
      return
    }
    guard R2ShareDestination.isActiveAccount(accountID) else {
      stopForAccountChange(uploadedCount: uploadedCount)
      return
    }
    R2ShareDestination.record(
      R2ShareDestination(
        accountID: accountID, bucket: destinationBucket, prefix: cleanPrefix,
        publicHost: host ?? ""))
    if let host, let lastKey, let url = Self.publicURL(host: host, key: lastKey) {
      UIPasteboard.general.url = url
      copiedURL = url
    }
    cleanupStaging()
    phase = .done
  }

  private func stopForAccountChange(uploadedCount: Int) {
    cleanupStaging()
    phase = .failed(
      uploadedCount == 0
        ? "The active Cloudflare account changed. Close this sheet and share again."
        : "The active Cloudflare account changed, so Dash stopped after \(uploadedCount) \(uploadedCount == 1 ? "file" : "files"). Check \(accountLabel) before sharing again."
    )
  }

  private func hasR2WriteAccess() async -> Bool {
    let grantedScopes = try? await tokenStore.getGrantedScopes()
    return R2ShareDestination.hasWriteAccess(grantedScopes: grantedScopes)
  }

  /// Prefers the host the app recorded for this bucket; falls back to asking
  /// Cloudflare directly (serving custom domain beats r2.dev).
  private func resolvePublicHost(accountID: String, bucket: String) async -> String? {
    if let known = R2ShareDestination.destination(accountID: accountID),
      known.bucket == bucket, !known.publicHost.isEmpty
    {
      return known.publicHost
    }
    let custom = (try? await client.listR2CustomDomains(accountID: accountID, bucket: bucket)) ?? []
    guard !Task.isCancelled, !requestEnded else { return nil }
    if let serving = custom.first(where: {
      $0.enabled && $0.status?.ownership == "active" && $0.status?.ssl == "active"
    }) {
      return serving.domain
    }
    if let managed = try? await client.getR2ManagedDomain(accountID: accountID, bucket: bucket),
      managed.enabled
    {
      guard !Task.isCancelled, !requestEnded else { return nil }
      return managed.domain
    }
    guard !Task.isCancelled, !requestEnded else { return nil }
    return nil
  }

  static func publicURL(host: String, key: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/" + key
    return components.url
  }

  struct LoadResult: Sendable {
    let attachments: [ShareAttachment]
    let oversizedNames: [String]
    let exceedsTotalLimit: Bool
  }

  static func load(
    providers: [NSItemProvider],
    stagingDirectory: URL
  ) async -> LoadResult {
    var out: [ShareAttachment] = []
    var oversized: [String] = []
    var totalBytes: Int64 = 0
    var exceedsTotalLimit = false
    for provider in providers {
      guard !Task.isCancelled else { break }
      guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
      switch await load(provider: provider, stagingDirectory: stagingDirectory) {
      case .attachment(let attachment):
        guard attachment.size <= totalSizeLimit - totalBytes else {
          try? FileManager.default.removeItem(at: attachment.fileURL)
          exceedsTotalLimit = true
          break
        }
        totalBytes += attachment.size
        out.append(attachment)
      case .oversized(let name):
        oversized.append(name)
        break
      case .unreadable: break
      }
      if !oversized.isEmpty || exceedsTotalLimit || Task.isCancelled { break }
    }
    return LoadResult(
      attachments: out,
      oversizedNames: oversized,
      exceedsTotalLimit: exceedsTotalLimit)
  }

  nonisolated private static func makeStagingDirectory() -> URL? {
    let stagingDirectory =
      stagingRoot
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: stagingDirectory, withIntermediateDirectories: true)
      return stagingDirectory
    } catch {
      return nil
    }
  }

  nonisolated static func removeStaleStagingDirectories(olderThan age: TimeInterval) {
    let root = stagingRoot
    Task.detached(priority: .utility) {
      guard
        let children = try? FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
          options: [.skipsHiddenFiles])
      else { return }
      let cutoff = Date().addingTimeInterval(-age)
      for child in children {
        let values = try? child.resourceValues(
          forKeys: [.contentModificationDateKey, .creationDateKey])
        let timestamp = values?.contentModificationDate ?? values?.creationDate
        if timestamp.map({ $0 < cutoff }) ?? true {
          try? FileManager.default.removeItem(at: child)
        }
      }
    }
  }

  private enum LoadedItem {
    case attachment(ShareAttachment)
    case oversized(String)
    case unreadable
  }

  private static func load(
    provider: NSItemProvider, stagingDirectory: URL
  ) async -> LoadedItem {
    let suggested = provider.suggestedName
    return await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
        guard let url else {
          continuation.resume(returning: .unreadable)
          return
        }
        let reportedSize =
          (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        guard
          reportedSize.map({ $0 >= 0 && $0 <= ShareUploadModel.perItemSizeLimit }) ?? true
        else {
          continuation.resume(returning: .oversized(suggested ?? url.lastPathComponent))
          return
        }
        var filename = url.lastPathComponent
        if let suggested, !suggested.isEmpty {
          let ext = url.pathExtension
          if ext.isEmpty || suggested.lowercased().hasSuffix("." + ext.lowercased()) {
            filename = suggested
          } else {
            filename = suggested + "." + ext
          }
        }
        var stagedURL =
          stagingDirectory
          .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        if !url.pathExtension.isEmpty {
          stagedURL.appendPathExtension(url.pathExtension)
        }
        do {
          let actualSize = try boundedStagingCopy(from: url, to: stagedURL)
          continuation.resume(
            returning: .attachment(
              ShareAttachment(
                filename: filename,
                fileURL: stagedURL,
                size: actualSize,
                contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)))
        } catch StagingCopyError.oversized {
          try? FileManager.default.removeItem(at: stagedURL)
          continuation.resume(returning: .oversized(filename))
        } catch {
          try? FileManager.default.removeItem(at: stagedURL)
          continuation.resume(returning: .unreadable)
        }
      }
    }
  }

  private enum StagingCopyError: Error {
    case cannotCreateDestination
    case oversized
  }

  /// Copies provider-owned files with a fixed 64 KB working set and stops
  /// before writing a byte beyond the per-item extension limit.
  nonisolated private static func boundedStagingCopy(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws -> Int64 {
    guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
      throw StagingCopyError.cannotCreateDestination
    }
    let source = try FileHandle(forReadingFrom: sourceURL)
    defer { try? source.close() }
    let destination = try FileHandle(forWritingTo: destinationURL)
    defer { try? destination.close() }

    var totalBytes: Int64 = 0
    while let chunk = try source.read(upToCount: stagingChunkSize), !chunk.isEmpty {
      let chunkSize = Int64(chunk.count)
      guard chunkSize <= perItemSizeLimit - totalBytes else {
        throw StagingCopyError.oversized
      }
      try destination.write(contentsOf: chunk)
      totalBytes += chunkSize
    }
    return totalBytes
  }

  private func cleanupStaging() {
    guard let stagingDirectory else { return }
    Self.removeStagingDirectory(stagingDirectory)
    self.stagingDirectory = nil
  }

  nonisolated private static func removeStagingDirectory(_ stagingDirectory: URL?) {
    guard let stagingDirectory else { return }
    try? FileManager.default.removeItem(at: stagingDirectory)
  }
}

struct ShareUploadView: View {
  @Bindable var model: ShareUploadModel
  @State private var showsUploadConfirmation = false

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Upload to R2")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { model.cancel() }
          }
          ToolbarItem(placement: .confirmationAction) {
            switch model.phase {
            case .ready:
              Button("Upload") { showsUploadConfirmation = true }
                .fontWeight(.semibold)
            case .done:
              Button("Done") { model.finish() }
                .fontWeight(.semibold)
            default:
              EmptyView()
            }
          }
        }
        .alert(
          "Upload to \(model.accountLabel)?",
          isPresented: $showsUploadConfirmation
        ) {
          Button("Cancel", role: .cancel) {}
          Button("Upload") { model.startUpload() }
        } message: {
          let folder = model.normalizedPrefix
          Text(
            folder.isEmpty
              ? "The files will be written to \(model.bucket)."
              : "The files will be written to \(model.bucket)/\(folder)."
          )
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      ProgressView("Preparing…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .signedOut:
      centered(
        systemImage: "person.crop.circle.badge.exclamationmark",
        message: "Sign in to Dash first, then share again.")
    case .authorizationRequired:
      VStack(spacing: 16) {
        Image(systemName: "lock.shield")
          .font(.system(size: 40))
          .foregroundStyle(.secondary)
        Text("R2 write access is required.")
          .font(.headline)
        Text(
          "Open Dash Settings, grant Shortcuts & Share write access, then share these files again."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        Button("Open Dash Settings") {
          model.openWriteAccessSettings()
        }
        .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let text):
      centered(systemImage: "exclamationmark.triangle", message: text)
    case .uploading(let current, let total):
      ProgressView(total > 1 ? "Uploading \(current) of \(total)…" : "Uploading…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .done:
      VStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 44))
          .foregroundStyle(.green)
        Text(
          model.attachments.count == 1
            ? "Uploaded \(model.attachments[0].filename)"
            : "Uploaded \(model.attachments.count) files"
        )
        .font(.headline)
        if model.copiedURL != nil {
          Text("Public URL copied to the clipboard.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .ready:
      form
    }
  }

  private var form: some View {
    Form {
      Section("Files") {
        ForEach(model.attachments) { attachment in
          LabeledContent(attachment.filename) {
            Text(
              ByteCountFormatter.string(
                fromByteCount: attachment.size, countStyle: .file))
          }
        }
      }
      Section("Destination") {
        LabeledContent("Account", value: model.accountLabel)
        if model.buckets.isEmpty {
          LabeledContent("Bucket", value: model.bucket)
        } else {
          Picker("Bucket", selection: $model.bucket) {
            ForEach(model.buckets) { bucket in
              Text(bucket.name).tag(bucket.name)
            }
          }
        }
        TextField("Folder (optional)", text: $model.prefix)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
    }
  }

  private func centered(systemImage: String, message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
