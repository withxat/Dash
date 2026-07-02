module.exports = function (api) {
	api.cache(true)
	return {
		// jsxImportSource: 'nativewind' lets className on RN primitives be typed
		// and processed by NativeWind's compiler.
		presets: [
			['babel-preset-expo', { jsxImportSource: 'nativewind' }],
			'nativewind/babel',
		],
		// Reanimated's plugin must be last.
		plugins: ['react-native-reanimated/plugin'],
	}
}
