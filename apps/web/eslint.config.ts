import { xat } from '@withxat/eslint-config'

export default xat({
	ignores: ['dist/**', '.wrangler/**', '.turbo/**', 'node_modules/**'],
	tailwindcss: {
		settings: {
			entryPoint: 'src/client/styles.css',
		},
	},
}, {
	// Worker unit tests run under node:test (see package.json "test"); do not
	// force vitest imports when vitest is not a dependency of this package.
	files: ['src/**/*.test.ts'],
	rules: {
		'test/no-import-node-test': 'off',
	},
})
