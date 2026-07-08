import SwiftUI

// Outline / line Solar assets use stroke-width 2 in their 24×24 SVGs.

enum SolarAsset {
  static let chevronRight = "SolarAltArrowRightOutline"
  static let chevronLeft = "SolarAltArrowLeftOutline"
  static let cloud = "SolarCloudOutline"
  static let plus = "SolarPlusOutline"
  static let circle = "SolarCircleOutline"
  static let checkCircle = "SolarCheckCircleOutline"
  static let shield = "SolarShieldOutline"
  static let shieldCheck = "SolarShieldCheckOutline"
  static let danger = "SolarDangerTriangleOutline"
  static let bolt = "SolarBoltOutline"
  static let globe = "SolarGlobalOutline"
  static let file = "SolarFileOutline"
  static let upload = "SolarUploadOutline"
  static let trash = "SolarTrashBinOutline"
  static let key = "SolarKeyOutline"
  static let database = "SolarDatabaseOutline"
  static let box = "SolarBoxMinimalisticOutline"
  static let pinList = "SolarPinListOutline"
  static let inbox = "SolarInboxOutline"
  static let gallery = "SolarGalleryOutline"
  static let video = "SolarVideoLibraryOutline"
  static let chart = "SolarChart2Outline"
  static let users = "SolarUsersGroupOutline"
  static let settings = "SolarSettingsMinimalisticOutline"
  static let code = "SolarCodeSquareOutline"
  static let codeCircle = "SolarCodeCircleOutline"
  static let letter = "SolarLetterOutline"
  static let routing = "SolarRoutingOutline"
  static let globus = "SolarGlobusOutline"
  static let branching = "SolarBranchingPathsUpOutline"
  static let lock = "SolarLockKeyholeOutline"
  static let heartPulse = "SolarHeartPulseOutline"
  static let sledgehammer = "SolarSledgehammerOutline"
  static let clock = "SolarClockCircleOutline"
  static let slider = "SolarSliderHorizontalOutline"
  static let search = "SolarMagnifierOutline"
  static let close = "SolarCloseOutline"
  static let menuDots = "SolarMenuDotsOutline"
  static let pen = "SolarPenNewSquareOutline"
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
