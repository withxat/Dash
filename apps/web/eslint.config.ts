import { xat } from '@withxat/eslint-config'

export default xat({
	ignores: ['dist/**', '.wrangler/**', '.turbo/**', 'node_modules/**'],
	tailwindcss: {
		settings: {
			entryPoint: 'src/client/styles.css',
		},
	},
})
