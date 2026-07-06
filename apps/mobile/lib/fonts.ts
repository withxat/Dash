import type { TextStyle } from 'react-native'

import ChillRoundGothicBold from '../assets/fonts/ChillRoundGothic_Bold.otf'

/** PostScript / Android asset name — tab-root screen titles. */
export const chillFontBold = 'ChillRoundGothic_Bold' as const

/** RN Text — static OTF; keep fontWeight 400 so RN does not synthesize bold. */
export function chillBoldTextStyle(extra?: TextStyle): TextStyle {
	return {
		fontFamily: chillFontBold,
		fontWeight: '400',
		...extra,
	}
}

/** Metro-bundled font file for expo-font runtime registration. */
export const chillFontAssets = {
	[chillFontBold]: ChillRoundGothicBold,
} as const
