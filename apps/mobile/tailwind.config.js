/** @type {import('tailwindcss').Config} */
module.exports = {
	content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
	presets: [require('nativewind/preset')],
	darkMode: 'media',
	theme: {
		extend: {
			colors: {
				brand: {
					DEFAULT: '#f6821f',
					foreground: '#ffffff',
				},
				canvas: {
					DEFAULT: '#0b0b0f',
					soft: '#131318',
					muted: '#1c1c23',
				},
			},
		},
	},
	plugins: [],
}
