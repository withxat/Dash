import SwiftUI

// Page and section identities use filled assets grouped under
// `SolarAsset.Content`. Navigation controls and action chrome use outline
// assets, generated at a visually bold 2pt weight.
// Small trailing row chevrons use 2.5pt; the navigation back mark stays at the
// shared 2pt chrome weight.

enum SolarAsset {
  enum Content {
    static let addCircle = "SolarAddCircleFill"
    static let bolt = "SolarBoltFill"
    static let box = "SolarBoxFill"
    static let boxMinimalistic = "SolarBoxMinimalisticFill"
    static let chart = "SolarChart2Fill"
    /// Bars inside a rounded square.
    static let chartSquare = "SolarChartSquareFill"
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
    static let inbox = "SolarInboxFill"
    static let mailbox = "SolarMailboxFill"
    static let key = "SolarKeyFill"
    static let lock = "SolarLockKeyholeFill"
    static let pinList = "SolarPinListFill"
    static let routing = "SolarRoutingFill"
    static let search = "SolarMagnifierFill"
    static let shieldCheck = "SolarShieldCheckFill"
    static let settings = "SolarSettingsMinimalisticFill"
    static let slider = "SolarSliderHorizontalFill"
    static let upload = "SolarUploadFill"
    static let user = "SolarUserFill"

    static let all: Set<String> = [
      addCircle, bolt, box, boxMinimalistic, chart, chartSquare, checkCircle,
      clock, cloud, code, codeCircle, danger, file, folder, globe, globus,
      graph, inbox, key, lock, mailbox, pinList, routing, search, settings, shieldCheck,
      slider, upload, user,
    ]
  }

  static let arrowRightUpBold = "SolarArrowRightUpBold"
  static let arrowRightDownBold = "SolarArrowRightDownBold"
  /// Linear external-link mark (Settings rows that leave the app).
  static let arrowRightUp = "SolarArrowRightUpOutline"
  static let chevronRight = "SolarAltArrowRightOutline"
  static let chevronLeft = "SolarAltArrowLeftOutline"
  static let cloud = "SolarCloudOutline"
  static let plus = "SolarPlusOutline"
  /// Solid add mark for Home quick actions.
  static let addCircleFill = "SolarAddCircleFill"
  static let circle = "SolarCircleOutline"
  static let checkCircle = "SolarCheckCircleOutline"
  /// Bare Solar check mark used for Done actions.
  static let unread = "SolarUnreadOutline"
  /// Selected state of a check control — solid, so "on" reads at a glance
  /// against the hollow `circle` of "off".
  static let checkCircleFill = "SolarCheckCircleFill"
  static let shield = "SolarShieldOutline"
  static let shieldCheck = "SolarShieldCheckOutline"
  static let danger = "SolarDangerTriangleOutline"
  static let bolt = "SolarBoltOutline"
  static let boltCircle = "SolarBoltCircleOutline"
  static let smartphoneVibration = "SolarSmartphoneVibrationOutline"
  static let sunset = "SolarSunsetOutline"
  static let globe = "SolarGlobalOutline"
  static let file = "SolarFileOutline"
  static let folder = "SolarFolderOutline"
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
  static let mailbox = "SolarMailboxOutline"
  static let gallery = "SolarGalleryOutline"
  static let video = "SolarVideoLibraryOutline"
  static let chart = "SolarChart2Outline"
  static let graph = "SolarGraphNewOutline"
  static let users = "SolarUsersGroupOutline"
  static let userCircle = "SolarUserCircleOutline"
  static let user = "SolarUserOutline"
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
  /// Heavy close mark — tray header ✕ only (`DashFormChrome` / sheet chrome).
  static let close = "SolarCloseOutline"
  /// 2pt close mark for page chrome (Settings dismiss, editor Cancel, etc.).
  static let editClose = "SolarEditCloseOutline"
  static let menuDots = "SolarMenuDotsOutline"
  /// `menuDots` rotated 90° — the horizontal dots that mark a row opening a
  /// picker tray (Language / Top glow / Chart style). Shares the same glyph;
  /// the rotation is applied at the call site via `SolarIcon.rotation`.
  static let trayDots = "SolarMenuDotsOutline"
  static let pen = "SolarPenNewSquareOutline"
  /// Not a Solar glyph: the Cloudflare brand mark (Simple Icons, filled).
  static let cloudflare = "CloudflareLogo"
  /// MingCute `github_line` — About → Developer.
  static let github = "MingCuteGithubLine"
  /// MingCute `social_x_line` — About → Developer.
  static let socialX = "MingCuteSocialXLine"
}

struct SolarIcon: View {
  let asset: String
  var size: CGFloat = 24
  var color: Color = DashTheme.text
  var rotation: Angle = .zero

  var body: some View {
    Image(asset)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .frame(width: size, height: size)
      .rotationEffect(rotation)
      .foregroundStyle(color)
      .accessibilityHidden(true)
  }
}
