import { Banner } from './banner'

/** Web-only Kumo component — not implemented on React Native. */
export function CommandPalette() {
	return (
		<Banner variant="warning">
			CommandPalette is not available on React Native. Use expo-router search or a dedicated screen.
		</Banner>
	)
}
