import { Banner } from './banner'

/** Web-only Kumo component — not implemented on React Native. */
export function Combobox() {
	return (
		<Banner variant="warning">
			Combobox is not available on React Native. Use Select with search in your screen.
		</Banner>
	)
}
