const plugin = require('tailwindcss/plugin')

// Chill Round Gothic (寒蝉圆黑体) is embedded natively via the expo-font config
// plugin (see app.json). Static OTFs expose one face per family, so each
// weight maps to its own fontFamily name (iOS PostScript name == Android
// asset file name). fontWeight is pinned to 400 so neither platform applies
// synthetic bolding on top of the already-weighted face.
const chill = {
	regular: 'ChillRoundGothic_Regular',
	medium: 'ChillRoundGothic_Medium',
	bold: 'ChillRoundGothic_Bold',
}

const chillFontPlugin = plugin(({ addUtilities, theme }) => {
	addUtilities({
		// Default the app font via the text-size utilities (every Text in the
		// app carries one). Weight/mono utilities below win when combined,
		// because they come later in this utilities layer.
		'.text-xs': { fontFamily: chill.regular },
		'.text-sm': { fontFamily: chill.regular },
		'.text-base': { fontFamily: chill.regular },
		'.text-lg': { fontFamily: chill.regular },
		'.text-xl': { fontFamily: chill.regular },
		'.text-2xl': { fontFamily: chill.regular },
		'.text-3xl': { fontFamily: chill.regular },
		'.text-4xl': { fontFamily: chill.regular },
		// Map the weight utilities to the matching static face.
		'.font-normal': { fontFamily: chill.regular, fontWeight: '400' },
		'.font-medium': { fontFamily: chill.medium, fontWeight: '400' },
		'.font-semibold': { fontFamily: chill.bold, fontWeight: '400' },
		'.font-bold': { fontFamily: chill.bold, fontWeight: '400' },
		// Keep code/monospace text on the platform mono font.
		'.font-mono': { fontFamily: theme('fontFamily.mono') },
	})
})

/** @type {import('tailwindcss').Config} */
module.exports = {
	content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
	presets: [require('nativewind/preset')],
	darkMode: 'media',
	theme: {
		extend: {
			borderRadius: {
				kumo: '20px',
			},
			colors: {
				accent: 'rgb(var(--color-accent) / <alpha-value>)',
				base: 'rgb(var(--color-base) / <alpha-value>)',
				badge: {
					blue: 'rgb(var(--color-badge-blue) / <alpha-value>)',
					green: 'rgb(var(--color-badge-green) / <alpha-value>)',
					inverted: 'rgb(var(--color-badge-inverted) / <alpha-value>)',
					'inverted-fg': 'rgb(var(--color-badge-inverted-fg) / <alpha-value>)',
					neutral: 'rgb(var(--color-badge-neutral) / <alpha-value>)',
					orange: 'rgb(var(--color-badge-orange) / <alpha-value>)',
					purple: 'rgb(var(--color-badge-purple) / <alpha-value>)',
					red: 'rgb(var(--color-badge-red) / <alpha-value>)',
					teal: 'rgb(var(--color-badge-teal) / <alpha-value>)',
					'teal-subtle': 'rgb(var(--color-badge-teal-subtle) / <alpha-value>)',
					'teal-subtle-fg': 'rgb(var(--color-badge-teal-subtle-fg) / <alpha-value>)',
				},
				brand: 'rgb(var(--color-brand) / <alpha-value>)',
				canvas: 'rgb(var(--color-canvas) / <alpha-value>)',
				control: 'rgb(var(--color-control) / <alpha-value>)',
				danger: {
					DEFAULT: 'rgb(var(--color-danger) / <alpha-value>)',
					tint: 'rgb(var(--color-danger-tint) / <alpha-value>)',
				},
				default: 'rgb(var(--color-default) / <alpha-value>)',
				elevated: 'rgb(var(--color-elevated) / <alpha-value>)',
				fill: 'rgb(var(--color-fill) / <alpha-value>)',
				focus: 'rgb(var(--color-focus) / <alpha-value>)',
				hairline: 'rgb(var(--color-hairline) / <alpha-value>)',
				info: {
					DEFAULT: 'rgb(var(--color-info) / <alpha-value>)',
					tint: 'rgb(var(--color-info-tint) / <alpha-value>)',
				},
				inverse: 'rgb(var(--color-inverse) / <alpha-value>)',
				line: 'rgb(var(--color-line) / <alpha-value>)',
				placeholder: 'rgb(var(--color-placeholder) / <alpha-value>)',
				recessed: 'rgb(var(--color-recessed) / <alpha-value>)',
				strong: 'rgb(var(--color-strong) / <alpha-value>)',
				subtle: 'rgb(var(--color-subtle) / <alpha-value>)',
				switch: {
					'track-off': 'rgb(var(--color-switch-track-off) / <alpha-value>)',
					'track-off-ring': 'rgb(var(--color-switch-track-off-ring) / <alpha-value>)',
					'track-on': 'rgb(var(--color-switch-track-on) / <alpha-value>)',
					'track-on-ring': 'rgb(var(--color-switch-track-on-ring) / <alpha-value>)',
				},
				success: {
					DEFAULT: 'rgb(var(--color-success) / <alpha-value>)',
					tint: 'rgb(var(--color-success-tint) / <alpha-value>)',
				},
				tint: 'rgb(var(--color-tint) / <alpha-value>)',
				warning: {
					DEFAULT: 'rgb(var(--color-warning) / <alpha-value>)',
					tint: 'rgb(var(--color-warning-tint) / <alpha-value>)',
				},
			},
			fontSize: {
				xs: ['12px', { lineHeight: '16px' }],
				sm: ['13px', { lineHeight: '18px' }],
				base: ['14px', { lineHeight: '20px' }],
				lg: ['16px', { lineHeight: '24px' }],
				xl: ['20px', { lineHeight: '26px' }],
				'2xl': ['22px', { lineHeight: '28px' }],
			},
		},
	},
	plugins: [chillFontPlugin],
}
