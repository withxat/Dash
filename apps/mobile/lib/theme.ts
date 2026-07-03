import { useColorScheme } from 'react-native'

/**
 * JS mirror of the Kumo semantic palette in global.css, for places that need
 * concrete color values (navigator chrome, ActivityIndicator, refresh
 * controls). Keep in sync with global.css.
 */
export interface ThemePalette {
	accent: string
	base: string
	brand: string
	canvas: string
	control: string
	danger: string
	dangerTint: string
	default: string
	elevated: string
	fill: string
	focus: string
	hairline: string
	info: string
	infoTint: string
	inverse: string
	line: string
	placeholder: string
	recessed: string
	shadowCard: string
	shadowElevated: string
	shadowOverlay: string
	shadowThumb: string
	strong: string
	subtle: string
	success: string
	successTint: string
	switchTrackNeutralOn: string
	switchTrackNeutralOnRing: string
	switchTrackOff: string
	switchTrackOffRing: string
	switchTrackOn: string
	switchTrackOnRing: string
	tint: string
	warning: string
	warningTint: string
}

export const lightPalette: ThemePalette = {
	accent: '#f6821f',
	base: '#ffffff',
	brand: '#1460e6',
	canvas: '#ffffff',
	control: '#ffffff',
	danger: '#ef4444',
	dangerTint: '#fee2e2',
	default: '#212126',
	elevated: '#fafafa',
	fill: '#e5e5e5',
	focus: '#171717',
	hairline: '#eeeeee',
	info: '#3b82f6',
	infoTint: '#dbeafe',
	inverse: '#ffffff',
	line: '#e5e5e5',
	placeholder: '#a3a3a3',
	recessed: '#f5f5f5',
	shadowCard: '0 1px 2px rgba(0, 0, 0, 0.04), 0 4px 16px rgba(0, 0, 0, 0.08)',
	shadowElevated: '0 1px 2px rgba(0, 0, 0, 0.05), 0 8px 24px rgba(0, 0, 0, 0.1)',
	shadowOverlay: '0 8px 32px rgba(0, 0, 0, 0.12), 0 2px 8px rgba(0, 0, 0, 0.08)',
	shadowThumb: '0 0 1px rgba(0, 0, 0, 0.12), 0 1px 2px rgba(0, 0, 0, 0.08)',
	strong: '#171717',
	subtle: '#717171',
	success: '#10b981',
	successTint: '#d1fae5',
	switchTrackNeutralOn: '#737373',
	switchTrackNeutralOnRing: '#525252',
	switchTrackOff: '#e5e5e5',
	switchTrackOffRing: '#d4d4d4',
	switchTrackOn: '#3b82f6',
	switchTrackOnRing: '#2563eb',
	tint: '#f7f7f7',
	warning: '#eab308',
	warningTint: '#fef9c3',
}

export const darkPalette: ThemePalette = {
	accent: '#f6821f',
	base: '#2b2b2b',
	brand: '#1256d6',
	canvas: '#1a1a1a',
	control: '#212126',
	danger: '#dc2626',
	dangerTint: '#450a0a',
	default: '#f5f5f5',
	elevated: '#1f1f1f',
	fill: '#404040',
	focus: '#eeeeee',
	hairline: '#404040',
	info: '#60a5fa',
	infoTint: '#1e3a8a',
	inverse: '#171717',
	line: '#525252',
	placeholder: '#717171',
	recessed: '#262626',
	shadowCard: '0 1px 2px rgba(0, 0, 0, 0.35), 0 4px 16px rgba(0, 0, 0, 0.28)',
	shadowElevated: '0 2px 4px rgba(0, 0, 0, 0.4), 0 12px 32px rgba(0, 0, 0, 0.32)',
	shadowOverlay: '0 12px 40px rgba(0, 0, 0, 0.45), 0 4px 12px rgba(0, 0, 0, 0.3)',
	shadowThumb: '0 0 1px rgba(255, 255, 255, 0.1), 0 1px 2px rgba(0, 0, 0, 0.35)',
	strong: '#fafafa',
	subtle: '#a3a3a3',
	success: '#34d399',
	successTint: '#064e3b',
	switchTrackNeutralOn: '#2b2b2b',
	switchTrackNeutralOnRing: '#404040',
	switchTrackOff: '#404040',
	switchTrackOffRing: '#525252',
	switchTrackOn: '#2563eb',
	switchTrackOnRing: '#3b82f6',
	tint: '#404040',
	warning: '#facc15',
	warningTint: '#713f12',
}

/** The palette for the current system appearance. */
export function useTheme(): ThemePalette {
	const scheme = useColorScheme()
	return scheme === 'dark' ? darkPalette : lightPalette
}
