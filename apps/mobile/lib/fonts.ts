import ChillRoundGothicHeavy from '../assets/fonts/ChillRoundGothic_Heavy.otf'

/** PostScript / Android asset name — large nav titles only. */
export const chillFontHeavy = 'ChillRoundGothic_Heavy' as const

/** Metro-bundled font file for expo-font runtime registration. */
export const chillFontAssets = {
	[chillFontHeavy]: ChillRoundGothicHeavy,
} as const
