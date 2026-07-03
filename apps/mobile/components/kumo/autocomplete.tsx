import { Banner } from './banner'

/** Web-only Kumo component — not implemented on React Native. */
export function Autocomplete() {
	return (
		<Banner variant="warning">
			Autocomplete is not available on React Native. Use Select or a searchable list pattern.
		</Banner>
	)
}
