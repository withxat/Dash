// NOTE: This is a .js (not .ts) config on purpose.
// eslint loads `.js` configs natively via dynamic import, avoiding jiti.
// The mobile app pulls Expo transitive deps that resolve an older jiti@1.21.7
// into eslint's module context, which eslint 10 rejects when loading .ts
// configs. Using ESM .js sidesteps jiti entirely. @withxat/eslint-config is
// `"type": "module"`, so the named import works.
import { xat } from '@withxat/eslint-config'

const config = xat({
	ignores: [
		'node_modules/**',
		'.expo/**',
		'.expo-shared/**',
		'android/**',
		'ios/**',
		'web-build/**',
		'babel.config.js',
		'metro.config.js',
		'tailwind.config.js',
	],
})

// React Native has no Node runtime: Metro polyfills `process` as a global.
// The `node/prefer-global/process` rule (and its autofix to `node:process`)
// breaks the RN bundle, so disable it app-wide. Add more node-* disables here
// if other Node-only rules fire on RN code.
config.append({
	name: 'cloudfx-mobile/react-native',
	rules: {
		'node/prefer-global/process': 'off',
	},
})

export default config
