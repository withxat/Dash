import { Banner } from './banner'

/** Web-only Kumo component — not implemented on React Native. */
export function DateRangePicker() {
	return (
		<Banner variant="warning">
			DateRangePicker is not available on React Native yet. Compose two DatePicker instances.
		</Banner>
	)
}
