import CloudflareAPI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Payload of one shared item, loaded eagerly because the provider's temp
/// file URL is only valid inside its completion handler.
struct ShareAttachment: Identifiable, Sendable {
  let id = UUID()
  let filename: String
  let data: Data
  let contentType: String?
}

/// Share-sheet entry point: hosts the SwiftUI flow and hands the extension
/// context's lifecycle callbacks to the model.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    guard let context = extensionContext else { return }
    let model = ShareUploadModel(
      finish: { context.completeRequest(returningItems: nil) },
      cancel: { context.cancelRequest(withError: CocoaError(.userCancelled)) })
    let host = UIHostingController(rootView: ShareUploadView(model: model))
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
    let providers = context.inputItems
      .compactMap { $0 as? NSExtensionItem }
      .flatMap { $0.attachments ?? [] }
    Task { await model.prepare(providers: providers) }
  }
}

@MainActor
@Observable
final class ShareUploadModel {
  enum Phase: Equatable {
    case loading
    case signedOut
    case ready
    case uploading(Int, Int)
    case done
    case failed(String)
  }

  /// Share extensions run under a far smaller memory ceiling than the app,
  /// and `putR2Object` buffers the body — cap transfers well below the
  /// in-app 100 MB limit. `nonisolated` so the NSItemProvider callback can
  /// read it without hopping to the main actor.
  nonisolated static let sizeLimit = 50 * 1024 * 1024

  let finish: () -> Void
  let cancel: () -> Void
  var attachments: [ShareAttachment] = []
  var buckets: [R2Bucket] = []
  var bucket = ""
  var prefix = ""
  var phase: Phase = .loading
  var copiedURL: URL?

  private let tokenStore = KeychainTokenStore()
  private let client: CloudflareClient
  private var accountID: String?

  init(finish: @escaping () -> Void, cancel: @escaping () -> Void) {
    self.finish = finish
    self.cancel = cancel
    client = CloudflareClient(
      clientID: AppConfiguration.current.clientID, tokenStore: tokenStore,
      session: DashAPISession.shared)
  }

  func prepare(providers: [NSItemProvider]) async {
    let token = (try? await tokenStore.getAccessToken()) ?? nil
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
    if let destination = R2ShareDestination.destination(accountID: accountID) {
      bucket = destination.bucket
      prefix = destination.prefix
    }
    let loaded = await Self.load(providers: providers)
    attachments = loaded.attachments
    // The picker degrades to a read-only label when this fails (offline) —
    // the remembered bucket still works.
    buckets = (try? await client.listR2Buckets(accountID: accountID)) ?? []
    if bucket.isEmpty { bucket = buckets.first?.name ?? "" }
    if attachments.isEmpty {
      phase = .failed(
        loaded.oversizedNames.isEmpty
          ? "Nothing Dash can upload was shared."
          : "\(loaded.oversizedNames[0]) is over the 50 MB share-sheet limit. Upload it from Dash instead."
      )
    } else if bucket.isEmpty {
      phase = .failed("No R2 buckets found in this account.")
    } else {
      phase = .ready
    }
  }

  var normalizedPrefix: String {
    var value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("/") { value.removeFirst() }
    if !value.isEmpty && !value.hasSuffix("/") { value += "/" }
    return value
  }

  func upload() async {
    guard let accountID, !bucket.isEmpty else { return }
    let cleanPrefix = normalizedPrefix
    var lastKey: String?
    // Camera batches repeat filenames; a duplicate key would overwrite the
    // object uploaded seconds earlier.
    var usedKeys = Set<String>()
    for (index, item) in attachments.enumerated() {
      phase = .uploading(index + 1, attachments.count)
      guard item.data.count <= Self.sizeLimit else {
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
          accountID: accountID, bucket: bucket, key: key, data: item.data,
          contentType: item.contentType)
        lastKey = key
      } catch {
        phase = .failed(error.localizedDescription)
        return
      }
    }
    let host = await resolvePublicHost(accountID: accountID)
    R2ShareDestination.record(
      R2ShareDestination(
        accountID: accountID, bucket: bucket, prefix: cleanPrefix, publicHost: host ?? ""))
    if let host, let lastKey, let url = Self.publicURL(host: host, key: lastKey) {
      UIPasteboard.general.url = url
      copiedURL = url
    }
    phase = .done
  }

  /// Prefers the host the app recorded for this bucket; falls back to asking
  /// Cloudflare directly (serving custom domain beats r2.dev).
  private func resolvePublicHost(accountID: String) async -> String? {
    if let known = R2ShareDestination.destination(accountID: accountID),
      known.bucket == bucket, !known.publicHost.isEmpty
    {
      return known.publicHost
    }
    let custom = (try? await client.listR2CustomDomains(accountID: accountID, bucket: bucket)) ?? []
    if let serving = custom.first(where: {
      $0.enabled && $0.status?.ownership == "active" && $0.status?.ssl == "active"
    }) {
      return serving.domain
    }
    if let managed = try? await client.getR2ManagedDomain(accountID: accountID, bucket: bucket),
      managed.enabled
    {
      return managed.domain
    }
    return nil
  }

  static func publicURL(host: String, key: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/" + key
    return components.url
  }

  static func load(
    providers: [NSItemProvider]
  ) async -> (attachments: [ShareAttachment], oversizedNames: [String]) {
    var out: [ShareAttachment] = []
    var oversized: [String] = []
    for provider in providers {
      guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
      switch await load(provider: provider) {
      case .attachment(let attachment): out.append(attachment)
      case .oversized(let name): oversized.append(name)
      case .unreadable: break
      }
    }
    return (out, oversized)
  }

  private enum LoadedItem {
    case attachment(ShareAttachment)
    case oversized(String)
    case unreadable
  }

  private static func load(provider: NSItemProvider) async -> LoadedItem {
    let suggested = provider.suggestedName
    return await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
        guard let url else {
          continuation.resume(returning: .unreadable)
          return
        }
        // Check the size before buffering — the extension's memory ceiling is
        // a fraction of the app's, and jetsam beats any error message.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= ShareUploadModel.sizeLimit else {
          continuation.resume(returning: .oversized(suggested ?? url.lastPathComponent))
          return
        }
        guard let data = try? Data(contentsOf: url) else {
          continuation.resume(returning: .unreadable)
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
        continuation.resume(
          returning: .attachment(
            ShareAttachment(
              filename: filename,
              data: data,
              contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)))
      }
    }
  }
}

struct ShareUploadView: View {
  @Bindable var model: ShareUploadModel

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
              Button("Upload") { Task { await model.upload() } }
                .fontWeight(.semibold)
            case .done:
              Button("Done") { model.finish() }
                .fontWeight(.semibold)
            default:
              EmptyView()
            }
          }
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
                fromByteCount: Int64(attachment.data.count), countStyle: .file))
          }
        }
      }
      Section("Destination") {
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
