// Adapted from VariableBlur
// https://github.com/nikstar/VariableBlur
// Upstream revision: 5073a0d9080e488a2d317e04859c001a57fbb3e8
//
// Copyright (c) 2012-2023 Nikita Starshinov, Scott Chacon, and others
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UIKit

enum DashVariableBlurDirection: Equatable {
  case blurredTopClearBottom
  case blurredBottomClearTop
}

struct DashVariableBlurConfiguration: Equatable {
  var maxBlurRadius: CGFloat = 20
  var direction: DashVariableBlurDirection = .blurredTopClearBottom
  var startOffset: CGFloat = 0

  var resolvedMaxBlurRadius: CGFloat {
    guard maxBlurRadius.isFinite else { return 0 }
    return max(0, maxBlurRadius)
  }

  var resolvedStartOffset: CGFloat {
    guard startOffset.isFinite else { return 0 }
    return min(max(startOffset, -1), 1)
  }
}

/// Bounds the private contract to OS releases and filter inputs whose shape
/// this vendored implementation knows. Unknown future iOS majors stay on the
/// public Material fallback instead of probing KVC keys that may have changed.
enum DashVariableBlurCompatibility {
  static let supportedOSMajorVersions = 17...26
  static let requiredInputKeys: Set<String> = [
    "inputMaskImage",
    "inputNormalizeEdges",
    "inputRadius",
  ]

  static func supports(osMajorVersion: Int) -> Bool {
    supportedOSMajorVersions.contains(osMajorVersion)
  }

  static var supportsCurrentOS: Bool {
    supports(
      osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )
  }

  static func supports(inputKeys: [String]) -> Bool {
    requiredInputKeys.isSubset(of: Set(inputKeys))
  }
}

/// Runtime support for the private variable-blur filter.
///
/// This is intentionally separate from OS availability: it verifies both the
/// filter factory and the complete installation path — including mask rendering
/// and backdrop discovery. Callers retain their public-API material fallback
/// when this is `false`.
@MainActor
enum DashVariableBlurSupport {
  static let isAvailable: Bool = {
    guard DashVariableBlurCompatibility.supportsCurrentOS else { return false }

    let probe = DashVariableBlurUIView(
      configuration: DashVariableBlurConfiguration()
    )
    return probe.isInstalled
  }()
}

struct DashVariableBlurView: UIViewRepresentable {
  private let configuration: DashVariableBlurConfiguration

  init(
    maxBlurRadius: CGFloat = 20,
    direction: DashVariableBlurDirection = .blurredTopClearBottom,
    startOffset: CGFloat = 0
  ) {
    configuration = DashVariableBlurConfiguration(
      maxBlurRadius: maxBlurRadius,
      direction: direction,
      startOffset: startOffset
    )
  }

  func makeUIView(context: Context) -> DashVariableBlurUIView {
    DashVariableBlurUIView(configuration: configuration)
  }

  func updateUIView(_ uiView: DashVariableBlurUIView, context: Context) {
    uiView.apply(configuration)
  }
}

/// A `UIVisualEffectView` provides the live backdrop layer needed by the
/// variable filter. Its regular effect exists only to vend that layer: until
/// installation succeeds the whole view stays transparent, avoiding a
/// hard-edged uniform-blur slab. The support probe keeps unsupported systems
/// on the caller's public Material path.
///
/// The filter setup is adapted from
/// https://github.com/jtrivedi/VariableBlurView, as credited by the upstream
/// VariableBlur implementation.
@MainActor
final class DashVariableBlurUIView: UIVisualEffectView {
  private var configuration: DashVariableBlurConfiguration
  private var installedFilter: NSObject?

  private(set) var isInstalled = false

  init(configuration: DashVariableBlurConfiguration) {
    self.configuration = configuration
    super.init(effect: UIBlurEffect(style: .regular))
    alpha = 0
    apply(configuration)
  }

  required init?(coder: NSCoder) {
    configuration = DashVariableBlurConfiguration()
    super.init(coder: coder)
    effect = UIBlurEffect(style: .regular)
    alpha = 0
  }

  func apply(_ configuration: DashVariableBlurConfiguration) {
    guard configuration != self.configuration || !isInstalled else { return }
    self.configuration = configuration

    guard
      let variableBlur = DashVariableBlurFilterFactory.makeFilter(),
      let gradientImage = DashVariableBlurGradientRenderer.makeImage(
        for: configuration
      ),
      let backdropLayer
    else {
      restoreTransparentFallback()
      return
    }

    variableBlur.setValue(
      configuration.resolvedMaxBlurRadius,
      forKey: "inputRadius"
    )
    variableBlur.setValue(gradientImage, forKey: "inputMaskImage")
    variableBlur.setValue(true, forKey: "inputNormalizeEdges")

    // Replace the standard gaussian and saturation filters with the spatially
    // varying blur. The other visual-effect subviews provide tint/dimming; hide
    // them only after the custom filter has installed successfully.
    backdropLayer.filters = [variableBlur]
    for subview in subviews.dropFirst() {
      subview.alpha = 0
    }

    installedFilter = variableBlur
    isInstalled = true
    alpha = 1
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    // The effect hierarchy can be attached after initialization. Retry once it
    // has a window before accepting the transparent fallback.
    if !isInstalled {
      apply(configuration)
    }

    guard
      isInstalled,
      let window,
      let backdropLayer,
      backdropLayer.responds(to: NSSelectorFromString("setScale:"))
    else { return }

    // Avoid pixelation at the clear edge on high-density displays.
    backdropLayer.setValue(
      window.traitCollection.displayScale,
      forKey: "scale"
    )
  }

  override func traitCollectionDidChange(
    _ previousTraitCollection: UITraitCollection?
  ) {
    // Calling through while the custom backdrop filter is installed crashes
    // on affected OS versions. The regular effect is transparent and exists
    // only to provide a backdrop layer, so it does not need UIKit tint updates.
    _ = previousTraitCollection
  }

  private var backdropLayer: CALayer? {
    subviews.first?.layer
  }

  private func restoreTransparentFallback() {
    let needsEffectReset = isInstalled
    isInstalled = false
    installedFilter = nil

    if needsEffectReset {
      effect = nil
      effect = UIBlurEffect(style: .regular)
      for subview in subviews {
        subview.alpha = 1
      }
    }

    alpha = 0
  }
}

@MainActor
private enum DashVariableBlurFilterFactory {
  static func makeFilter() -> NSObject? {
    guard DashVariableBlurCompatibility.supportsCurrentOS else { return nil }

    let className = String("retliFAC".reversed())
    let factorySelector = NSSelectorFromString(
      String(":epyThtiWretlif".reversed())
    )

    guard
      let filterClass = NSClassFromString(className) as? NSObject.Type,
      filterClass.responds(to: factorySelector),
      let result = filterClass.perform(
        factorySelector,
        with: "variableBlur"
      ),
      let filter = result.takeUnretainedValue() as? NSObject,
      supportsRequiredInputs(filter)
    else { return nil }

    return filter
  }

  private static func supportsRequiredInputs(_ filter: NSObject) -> Bool {
    let inputKeysSelector = NSSelectorFromString("inputKeys")
    guard
      filter.responds(to: inputKeysSelector),
      let result = filter.perform(inputKeysSelector),
      let inputKeys = result.takeUnretainedValue() as? [String]
    else { return false }

    return DashVariableBlurCompatibility.supports(inputKeys: inputKeys)
  }
}

@MainActor
private enum DashVariableBlurGradientRenderer {
  /// `CIContext` is deliberately reused; constructing one per screen is
  /// expensive and can create a separate render cache for every header.
  static let context = CIContext()

  static func makeImage(
    for configuration: DashVariableBlurConfiguration,
    width: CGFloat = 100,
    height: CGFloat = 100
  ) -> CGImage? {
    let gradient = CIFilter.linearGradient()
    gradient.color0 = CIColor.black
    gradient.color1 = CIColor.clear
    gradient.point0 = CGPoint(x: 0, y: height)
    gradient.point1 = CGPoint(
      x: 0,
      y: configuration.resolvedStartOffset * height
    )

    if configuration.direction == .blurredBottomClearTop {
      gradient.point0.y = 0
      gradient.point1.y = height - gradient.point1.y
    }

    guard let outputImage = gradient.outputImage else { return nil }
    return context.createCGImage(
      outputImage,
      from: CGRect(x: 0, y: 0, width: width, height: height)
    )
  }
}
