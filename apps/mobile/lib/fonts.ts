import ChillRoundGothicBold from '../assets/fonts/ChillRoundGothic_Bold.otf'
import ChillRoundGothicHeavy from '../assets/fonts/ChillRoundGothic_Heavy.otf'
import ChillRoundGothicMedium from '../assets/fonts/ChillRoundGothic_Medium.otf'

/** PostScript / Android asset names for embedded Chill Round Gothic faces. */
export const chillFonts = {
	bold: 'ChillRoundGothic_Bold',
	heavy: 'ChillRoundGothic_Heavy',
	medium: 'ChillRoundGothic_Medium',
} as const

export type ChillFontName = typeof chillFonts[keyof typeof chillFonts]

/** Metro-bundled font files for expo-font runtime registration. */
export const chillFontAssets: Record<ChillFontName, number> = {
	[chillFonts.bold]: ChillRoundGothicBold,
	[chillFonts.heavy]: ChillRoundGothicHeavy,
	[chillFonts.medium]: ChillRoundGothicMedium,
}
