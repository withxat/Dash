import SwiftUI

// UI chrome uses outline Solar assets. Content surfaces use the filled assets
// grouped under `SolarAsset.Content`.
// Chevrons use a 2.5 outline so they stay legible when scaled below 24pt.

enum SolarAsset {
  enum Content {
    static let addCircle = "SolarAddCircleFill"
    static let bolt = "SolarBoltFill"
    static let box = "SolarBoxFill"
    static let boxMinimalistic = "SolarBoxMinimalisticFill"
    static let chart = "SolarChart2Fill"
    static let checkCircle = "SolarCheckCircleFill"
    static let clock = "SolarClockCircleFill"
    static let cloud = "SolarCloudFill"
    static let code = "SolarCodeSquareFill"
    static let codeCircle = "SolarCodeCircleFill"
    static let danger = "SolarDangerTriangleFill"
    static let file = "SolarFileFill"
    static let folder = "SolarFolderFill"
    static let globe = "SolarGlobalFill"
    static let globus = "SolarGlobusFill"
    static let graph = "SolarGraphNewFill"
    static let key = "SolarKeyFill"
    static let lock = "SolarLockKeyholeFill"
    static let pinList = "SolarPinListFill"
    static let search = "SolarMagnifierFill"
    static let shieldCheck = "SolarShieldCheckFill"
    static let settings = "SolarSettingsMinimalisticFill"
    static let slider = "SolarSliderHorizontalFill"
    static let upload = "SolarUploadFill"

    static let all: Set<String> = [
      addCircle, bolt, box, boxMinimalistic, chart, checkCircle, clock, cloud,
      code, codeCircle, danger, file, folder, globe, globus, graph, key, lock,
      pinList, search, settings, shieldCheck, slider, upload,
    ]
  }

  static let chevronRight = "SolarAltArrowRightOutline"
  static let chevronLeft = "SolarAltArrowLeftOutline"
  static let cloud = "SolarCloudOutline"
  static let plus = "SolarPlusOutline"
  /// Solid add mark for Home quick actions.
  static let addCircleFill = "SolarAddCircleFill"
  static let circle = "SolarCircleOutline"
  static let checkCircle = "SolarCheckCircleOutline"
  /// Selected state of a check control — solid, so "on" reads at a glance
  /// against the hollow `circle` of "off".
  static let checkCircleFill = "SolarCheckCircleFill"
  static let shield = "SolarShieldOutline"
  static let shieldCheck = "SolarShieldCheckOutline"
  static let danger = "SolarDangerTriangleOutline"
  static let bolt = "SolarBoltOutline"
  static let boltCircle = "SolarBoltCircleOutline"
  static let globe = "SolarGlobalOutline"
  static let file = "SolarFileOutline"
  static let upload = "SolarUploadOutline"
  static let trash = "SolarTrashBinOutline"
  static let key = "SolarKeyOutline"
  static let database = "SolarDatabaseOutline"
  static let box = "SolarBoxOutline"
  static let boxFill = "SolarBoxFill"
  static let boxMinimalistic = "SolarBoxMinimalisticOutline"
  static let pinList = "SolarPinListOutline"
  static let pin = "SolarPinOutline"
  static let pinFilled = "SolarPinFill"
  static let inbox = "SolarInboxOutline"
  static let gallery = "SolarGalleryOutline"
  static let video = "SolarVideoLibraryOutline"
  static let chart = "SolarChart2Outline"
  static let users = "SolarUsersGroupOutline"
  static let userCircle = "SolarUserCircleOutline"
  static let user = "SolarUserOutline"
  /// Solid user mark for Profile surfaces.
  static let userFill = "SolarUserFill"
  static let settings = "SolarSettingsMinimalisticOutline"
  static let code = "SolarCodeSquareOutline"
  /// Bare `</>` brackets (no square) — Home Workers quick action.
  static let codeOutline = "SolarCodeOutline"
  static let codeCircle = "SolarCodeCircleOutline"
  static let codeCircleFill = "SolarCodeCircleFill"
  static let routing = "SolarRoutingOutline"
  static let globus = "SolarGlobusOutline"
  static let lock = "SolarLockKeyholeOutline"
  static let heartPulse = "SolarHeartPulseOutline"
  static let clock = "SolarClockCircleOutline"
  static let slider = "SolarSliderHorizontalOutline"
  static let search = "SolarMagnifierOutline"
  static let close = "SolarCloseOutline"
  static let menuDots = "SolarMenuDotsOutline"
  static let pen = "SolarPenNewSquareOutline"
  /// Not a Solar glyph: the Cloudflare brand mark (Simple Icons, filled).
  static let cloudflare = "CloudflareLogo"
}

struct SolarIcon: View {
  let asset: String
  var size: CGFloat = 24
  var color: Color = DashTheme.text

  var body: some View {
    Image(asset)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .frame(width: size, height: size)
      .foregroundStyle(color)
      .accessibilityHidden(true)
  }
}
