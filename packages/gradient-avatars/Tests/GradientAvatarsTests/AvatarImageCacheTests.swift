import CoreGraphics
import Foundation
import Testing

@testable import GradientAvatars

@Test func imageCacheDeduplicatesConcurrentRequests() async throws {
  let renderCount = LockedCounter()
  let cache = makeCache(renderCount: renderCount)
  let request = AvatarImageRequest(
    seed: AvatarSeed("shared"),
    pixelSize: 64,
    pattern: .dither
  )

  let snapshots = await withTaskGroup(
    of: AvatarImageSnapshot?.self,
    returning: [AvatarImageSnapshot?].self
  ) { group in
    for _ in 0..<24 {
      group.addTask {
        await cache.image(for: request)
      }
    }

    var values: [AvatarImageSnapshot?] = []
    for await snapshot in group {
      values.append(snapshot)
    }
    return values
  }

  #expect(snapshots.count == 24)
  #expect(snapshots.allSatisfy { $0?.request == request })
  #expect(renderCount.value == 1)
  #expect(cache.cachedImage(for: request) != nil)
}

@Test func imageCacheKeysIncludePixelSizeAndPattern() async throws {
  let renderCount = LockedCounter()
  let cache = makeCache(renderCount: renderCount)
  let requests = [
    AvatarImageRequest(seed: AvatarSeed(42), pixelSize: 32, pattern: .mesh),
    AvatarImageRequest(seed: AvatarSeed(42), pixelSize: 64, pattern: .mesh),
    AvatarImageRequest(seed: AvatarSeed(42), pixelSize: 64, pattern: .dither),
  ]

  for request in requests {
    _ = try #require(await cache.image(for: request))
    _ = try #require(await cache.image(for: request))
  }

  #expect(renderCount.value == requests.count)
}

@Test func canceledQueuedImageRequestSkipsRendering() async throws {
  let renderCount = LockedCounter()
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let blockingRequest = AvatarImageRequest(
    seed: AvatarSeed("blocking"),
    pixelSize: 32,
    pattern: .dither
  )
  let canceledRequest = AvatarImageRequest(
    seed: AvatarSeed("canceled"),
    pixelSize: 32,
    pattern: .dither
  )
  let cache = AvatarImageCache { request in
    renderCount.increment()
    if request == blockingRequest {
      started.signal()
      release.wait()
    }
    return renderedImage(for: request)
  }

  let first = Task {
    await cache.image(for: blockingRequest)
  }
  await wait(for: started)

  let canceled = Task {
    await cache.image(for: canceledRequest)
  }
  canceled.cancel()
  release.signal()

  _ = try #require(await first.value)
  #expect(await canceled.value == nil)
  #expect(renderCount.value == 1)
  #expect(cache.cachedImage(for: canceledRequest) == nil)
}

private func makeCache(renderCount: LockedCounter) -> AvatarImageCache {
  AvatarImageCache(memory: AvatarImageMemoryCache(countLimit: 16)) { request in
    renderCount.increment()
    return renderedImage(for: request)
  }
}

private func renderedImage(
  for request: AvatarImageRequest
) -> AvatarRenderedImage? {
  AvatarRenderer.image(
    seed: request.seed,
    size: request.pixelSize,
    pattern: request.pattern
  ).map(AvatarRenderedImage.init)
}

private func wait(for semaphore: DispatchSemaphore) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      semaphore.wait()
      continuation.resume()
    }
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
