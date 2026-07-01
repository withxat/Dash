import { xat } from '@withxat/eslint-config'

const config = xat({
	ignores: [
		'apps/**/*',
		'packages/**/*',
	],
})

export default config
