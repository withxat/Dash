import CloudflareAPI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - QuickLook

/// Native Quick Look in a navigation stack. Dash only adds Done + ⋯ — no
/// chrome stripping, no SwiftUI overlay over the preview surface (that stole
/// pinch / pan hits and made the interaction feel wrong).
struct QuickLookPreview: UIViewControllerRepresentable {
  let url: URL
  var onDismiss: () -> Void
  var onMore: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(url: url, onDismiss: onDismiss, onMore: onMore)
  }

  func makeUIViewController(context: Context) -> UINavigationController {
    let preview = DashQLPreviewController()
    preview.dataSource = context.coordinator
    preview.delegate = context.coordinator
    context.coordinator.attach(to: preview)
    preview.reloadData()
    return UINavigationController(rootViewController: preview)
  }

  func updateUIViewController(_ nav: UINavigationController, context: Context) {
    context.coordinator.url = url
    context.coordinator.onDismiss = onDismiss
    context.coordinator.onMore = onMore
    guard let preview = nav.topViewController as? DashQLPreviewController else { return }
    let urlChanged = preview.previewingURL != url
    context.coordinator.attach(to: preview)
    if urlChanged {
      preview.reloadData()
    }
    preview.applyDashChrome()
  }

  // The coordinator inherits @MainActor from the representable; the delegate
  // protocol is nonisolated, so the conformance must be declared isolated —
  // QuickLook only calls it on the main thread.
  final class Coordinator: NSObject, QLPreviewControllerDataSource,
    @MainActor QLPreviewControllerDelegate
  {
    var url: URL
    var onDismiss: () -> Void
    var onMore: () -> Void

    init(url: URL, onDismiss: @escaping () -> Void, onMore: @escaping () -> Void) {
      self.url = url
      self.onDismiss = onDismiss
      self.onMore = onMore
    }

    fileprivate func attach(to preview: DashQLPreviewController) {
      preview.previewingURL = url
      if preview.dashDone == nil {
        preview.dashDone = UIBarButtonItem(
          barButtonSystemItem: .done,
          target: self,
          action: #selector(done)
        )
      }
      if preview.dashMore == nil {
        let more = UIBarButtonItem(
          image: UIImage(systemName: "ellipsis.circle"),
          style: .plain,
          target: self,
          action: #selector(more)
        )
        more.accessibilityLabel = DashL10n.string("More actions")
        more.tag = DashQLPreviewController.moreButtonTag
        preview.dashMore = more
      }
      preview.applyDashChrome()
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> QLPreviewItem
    {
      url as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
      onDismiss()
    }

    @objc func done() { onDismiss() }
    @objc func more() { onMore() }
  }
}

/// `QLPreviewController` rewrites bar items when content loads; re-assert Done / ⋯
/// after each layout pass so the system share control can stay beside ours.
private final class DashQLPreviewController: QLPreviewController {
  static let moreButtonTag = 7_201

  var previewingURL: URL?
  var dashDone: UIBarButtonItem?
  var dashMore: UIBarButtonItem?

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyDashChrome()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    applyDashChrome()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyDashChrome()
  }

  func applyDashChrome() {
    if let dashDone {
      navigationItem.leftBarButtonItem = dashDone
    }
    guard let dashMore else { return }
    var rights = navigationItem.rightBarButtonItems ?? []
    rights.removeAll { $0.tag == Self.moreButtonTag }
    rights.insert(dashMore, at: 0)
    navigationItem.rightBarButtonItems = rights
  }
}

// MARK: - Object preview

/// Downloads the object, then hands it to native Quick Look. Loading / oversized /
/// failed states keep a light SwiftUI shell; the ready state is system QL only.
struct R2ObjectPreview: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let bucket: String
  let object: R2Object
  let publicURL: URL?
  let allowsWrites: Bool
  var onMutated: () async -> Void

  @State private var localURL: URL?
  @State private var status: Status = .loading
  @State private var showsActions = false

  private enum Status: Equatable { case loading, ready, tooLarge, failed }

  private var filename: String {
    object.key.split(separator: "/").last.map(String.init) ?? object.key
  }

  var body: some View {
    Group {
      if status == .ready, let localURL {
        QuickLookPreview(
          url: localURL,
          onDismiss: { dismiss() },
          onMore: { showsActions = true }
        )
        .ignoresSafeArea()
      } else {
        fallbackShell
      }
    }
    .task { await download() }
    .onDisappear(perform: cleanup)
    // Keep the browser mounted behind the cover (QuickLook and this view's own
    // stage still draw opaque on top): an opaque cover would fire the browser's
    // .onDisappear and cancel any in-flight upload the moment a row is tapped.
    .presentationBackground(.clear)
    .dashTray(isPresented: $showsActions, title: filename) {
      R2ObjectActionsSheet(
        bucket: bucket,
        object: object,
        publicURL: publicURL,
        allowsWrites: allowsWrites,
        // The sheet dismisses itself, then this closure (owned by the browser)
        // clears the preview's item binding and reloads the listing — each
        // presentation layer is torn down by its own owner.
        onMutated: onMutated
      )
    }
  }

  /// Pre-QL states only — chrome is a top inset so it never covers the (future)
  /// preview hit target the way the old full-screen overlay did.
  private var fallbackShell: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      fallback
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack(spacing: 12) {
        PreviewChromeButton(
          asset: SolarAsset.close, accessibilityLabel: "Close", action: { dismiss() })
        Text(filename)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(.white)
          .lineLimit(1)
          .frame(maxWidth: .infinity)
        PreviewChromeButton(
          asset: SolarAsset.menuDots, accessibilityLabel: "More actions",
          action: { showsActions = true })
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, 8)
      .background(
        LinearGradient(
          colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)
      )
    }
  }

  private var fallback: some View {
    VStack(spacing: 16) {
      SolarIcon(
        asset: FileTypeIcon.asset(forKey: object.key), size: 72,
        color: Color.white.opacity(0.35))
      VStack(spacing: 4) {
        Text(fallbackMessage)
          .dashTextStyle(.footnote)
          .foregroundStyle(Color.white.opacity(0.55))
          .multilineTextAlignment(.center)
      }
      if status == .loading {
        DashLoadingRing(color: DashTheme.brand)
          .padding(.top, 4)
      }
    }
    .padding(DashTheme.Spacing.screen)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var fallbackMessage: String {
    switch status {
    case .loading: "Loading preview…"
    case .tooLarge:
      "Too large to preview on device. Use the ⋯ menu to copy its public URL."
    case .failed: "Couldn't load a preview. Try the ⋯ menu for other actions."
    case .ready: ""
    }
  }

  private func download() async {
    guard status == .loading, let accountID = model.activeAccountID else { return }
    guard (object.size ?? 0) <= R2Media.transferSizeLimit else {
      status = .tooLarge
      return
    }
    do {
      let data = try await model.client.getR2Object(
        accountID: accountID, bucket: bucket, key: object.key)
      let url = try await Self.writeTempFile(data: data, filename: filename)
      localURL = url
      status = .ready
    } catch {
      status = error.dashIsCancellation ? .loading : .failed
    }
  }

  /// QuickLook keys type detection off the file extension, so the temp copy
  /// keeps the object's own filename inside a unique directory to avoid
  /// collisions between two objects sharing a name.
  private static func writeTempFile(data: Data, filename: String) async throws -> URL {
    try await Task.detached(priority: .userInitiated) {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("r2-preview", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let safeName = filename.isEmpty ? "object" : filename
      let url = directory.appendingPathComponent(safeName)
      try data.write(to: url, options: .atomic)
      return url
    }.value
  }

  // Fires only on genuine dismissal: the transparent actions tray keeps this
  // view mounted, so covering it does not delete the file QuickLook is showing.
  private func cleanup() {
    guard let localURL else { return }
    try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
  }
}

/// Floating circular control for the pre-QL loading / error shell only.
private struct PreviewChromeButton: View {
  let asset: String
  var accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      SolarIcon(asset: asset, size: 18, color: .white)
        .frame(width: 36, height: 36)
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
          Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .dashCompactHitTarget()
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
  }
}

// MARK: - Actions sheet

/// The object's actions, reached from the preview's "⋯" button: Copy public
/// URL, Rename (morphs to a key editor in place), Download / share, and a
/// header-trash delete. Also lists the object's metadata fields. Rename and
/// delete run the download → PUT → delete dance through `CloudflareClient`;
/// there is no server-side copy.
private struct R2ObjectActionsSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let bucket: String
  let object: R2Object
  let publicURL: URL?
  let allowsWrites: Bool
  var onMutated: () async -> Void
  @State private var renaming = false
  @State private var newKey = ""
  @State private var renameBusy = false
  @State private var renameError: String?
  @State private var renamePhase: String?
  @State private var deleting = false
  @State private var deleteError: String?

  private var filename: String {
    object.key.split(separator: "/").last.map(String.init) ?? object.key
  }

  /// Rename buffers the whole object on the phone, so oversized objects only
  /// offer Download.
  private var canRename: Bool {
    allowsWrites && (object.size ?? 0) <= R2Media.transferSizeLimit
  }

  private var normalizedKey: String? {
    var value = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("/") { value.removeFirst() }
    guard !value.isEmpty, !value.hasSuffix("/"), value != object.key else { return nil }
    return value
  }

  var body: some View {
    ZStack {
      if renaming {
        renameForm
          .transition(reduceMotion ? .opacity : .dashMorph)
      } else {
        detail
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
    .dashTrayTitle(renaming ? "Rename" : nil)
  }

  private var detail: some View {
    DashDetailTray(
      fields: object.detailFields,
      deleteMessage: allowsWrites
        ? DashL10n.string("Permanently deletes \(filename) from \(bucket). This can't be undone.")
        : nil,
      isDeleting: deleting,
      deleteError: deleteError,
      onDelete: allowsWrites ? { Task { await performDelete() } } : nil
    ) {
      VStack(spacing: 10) {
        if let publicURL {
          DashActionButton(title: "Copy public URL") {
            UIPasteboard.general.url = publicURL
            model.toasts.success(DashL10n.string("Public URL copied."))
          }
        } else if canRename {
          // No public URL — Rename is the primary verb.
          DashActionButton(title: "Rename") {
            newKey = object.key
            renameError = nil
            withAnimation(DashTheme.Motion.morph) { renaming = true }
          }
        } else if let accountID = model.activeAccountID,
          (object.size ?? 0) <= R2Media.transferSizeLimit
        {
          // Download-only tray: ShareLink styled as the primary action.
          ShareLink(
            item: R2ObjectExport(
              client: model.client, accountID: accountID, bucket: bucket, key: object.key),
            preview: SharePreview(object.key)
          ) {
            Text("Download")
              .dashTextStyle(.button)
              .foregroundStyle(DashTheme.inverse)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(DashTheme.strong, in: DashTheme.pillShape)
          }
          .buttonStyle(DashPressButtonStyle())
        }

        if publicURL != nil, canRename {
          DashTrayPillButton(title: "Rename") {
            newKey = object.key
            renameError = nil
            withAnimation(DashTheme.Motion.morph) { renaming = true }
          }
        }
        // Download buffers the whole body in memory, so it shares the
        // on-device transfer ceiling with rename and move.
        if publicURL != nil || canRename,
          let accountID = model.activeAccountID,
          (object.size ?? 0) <= R2Media.transferSizeLimit
        {
          ShareLink(
            item: R2ObjectExport(
              client: model.client, accountID: accountID, bucket: bucket, key: object.key),
            preview: SharePreview(object.key)
          ) {
            Text("Download")
              .dashTextStyle(.buttonBold)
              .foregroundStyle(DashTheme.strong)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(DashTheme.recessed, in: DashTheme.pillShape)
              .dashShadow(.border, in: DashTheme.pillShape)
          }
          .buttonStyle(DashPressButtonStyle())
        }
      }
    }
  }

  private var renameForm: some View {
    DashFormSheet(
      saveTitle: "Rename",
      isSaving: renameBusy,
      canSave: normalizedKey != nil,
      onSave: { Task { await performRename() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(label: "Key", text: $newKey)
          Text(
            "Moving between folders is just renaming the key — use / to nest. The object is copied to the new key, then the old one is deleted."
          )
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
          if let renamePhase {
            Text(renamePhase)
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
          }
          if let renameError {
            DashNotice(kind: .error, message: renameError)
          }
          Button {
            withAnimation(DashTheme.Motion.morph) { renaming = false }
          } label: {
            Text("Back")
              .dashTextStyle(.buttonMedium)
              .foregroundStyle(DashTheme.subtle)
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(DashPressButtonStyle())
          .disabled(renameBusy)
        }
      }
    )
  }

  private func performRename() async {
    guard let accountID = model.activeAccountID, let target = normalizedKey else { return }
    renameBusy = true
    renameError = nil
    do {
      // A plain PUT replaces silently — refuse to rename onto a taken key.
      renamePhase = "Checking destination…"
      let collision = try await model.client.listR2Objects(
        accountID: accountID, bucket: bucket, prefix: target)
      guard !collision.objects.contains(where: { $0.key == target }) else {
        renameError = DashL10n.string("An object already exists at \(target).")
        DashDelight.failError()
        renameBusy = false
        renamePhase = nil
        return
      }
      renamePhase = "Downloading…"
      let data = try await model.client.getR2Object(
        accountID: accountID, bucket: bucket, key: object.key)
      renamePhase = DashL10n.string("Uploading as \(target)…")
      try await model.client.putR2Object(
        accountID: accountID, bucket: bucket, key: target, data: data,
        contentType: object.contentType ?? R2Media.mimeType(forKey: target))
      renamePhase = "Removing old key…"
      try await model.client.deleteR2Object(
        accountID: accountID, bucket: bucket, key: object.key)
      model.toasts.success(DashL10n.string("Renamed to \(target)."))
      dismiss()
      await onMutated()
    } catch {
      renameError = error.dashActionableMessage
      DashDelight.failError()
    }
    renameBusy = false
    renamePhase = nil
  }

  private func performDelete() async {
    guard let accountID = model.activeAccountID else { return }
    deleting = true
    do {
      try await model.client.deleteR2Object(accountID: accountID, bucket: bucket, key: object.key)
      model.toasts.success(DashL10n.string("Deleted \(filename)."))
      dismiss()
      await onMutated()
    } catch {
      deleteError = error.dashActionableMessage
      DashDelight.failError()
    }
    deleting = false
  }
}

private struct R2ObjectExport: Transferable {
  let client: CloudflareClient
  let accountID: String
  let bucket: String
  let key: String

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { export in
      let data = try await export.client.getR2Object(
        accountID: export.accountID, bucket: export.bucket, key: export.key)
      let filename = export.key.split(separator: "/").last.map(String.init) ?? export.key
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
      try data.write(to: url)
      return SentTransferredFile(url)
    }
  }
}
