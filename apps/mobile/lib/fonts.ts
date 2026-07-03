import type { TextStyle } from 'react-native'

import ChillRoundGothicBold from '../assets/fonts/ChillRoundGothic_Bold.otf'
import ChillRoundGothicHeavy from '../assets/fonts/ChillRoundGothic_Heavy.otf'
import ChillRoundGothicMedium from '../assets/fonts/ChillRoundGothic_Medium.otf'

/** PostScript / Android asset names for embedded Chill Round Gothic faces. */
export const chillFonts = {
	bold: 'ChillRoundGothic_Bold',
	heavy: 'ChillRoundGothic_Heavy',
	medium: 'ChillRoundGothic_Medium',
} as const

export type ChillFace = keyof typeof chillFonts
export type ChillFontName = typeof chillFonts[keyof typeof chillFonts]

/**
 * RN Text — static OTF face only; pin fontWeight 400 so RN does not fake-bold.
 * Tailwind: font-normal → medium, font-medium → bold, font-bold → heavy.
 */
export function chillFaceStyle(face: ChillFace, extra?: TextStyle): TextStyle {
	return {
		fontFamily: chillFonts[face],
		fontWeight: '400',
		...extra,
	}
}

/**
 * UIKit nav-bar titles (react-native-screens → RCTFont). PostScript names are not
 * family names: RCTFont loads the face then re-picks a sibling by fontWeight.
 * Weight 400 always lands on Medium; map each face to a UIFontWeight instead.
 */
const nativeHeaderWeight = {
	bold: '700',
	heavy: '800',
	medium: '500',
} as const satisfies Record<ChillFace, string>

export function chillNativeHeaderStyle(face: ChillFace, extra?: TextStyle): TextStyle {
	return {
		fontFamily: chillFonts[face],
		fontWeight: nativeHeaderWeight[face],
		...extra,
	}
}

/** Metro-bundled font files for expo-font runtime registration. */
export const chillFontAssets: Record<ChillFontName, number> = {
	[chillFonts.bold]: ChillRoundGothicBold,
	[chillFonts.heavy]: ChillRoundGothicHeavy,
	[chillFonts.medium]: ChillRoundGothicMedium,
}
