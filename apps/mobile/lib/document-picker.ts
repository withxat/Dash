import { requireOptionalNativeModule } from 'expo-modules-core'

export function isDocumentPickerAvailable(): boolean {
	return requireOptionalNativeModule('ExpoDocumentPicker') != null
}

export async function pickDocumentAsync() {
	if (!isDocumentPickerAvailable())
		throw new Error('document-picker-unavailable')

	const DocumentPicker = await import('expo-document-picker')
	return DocumentPicker.getDocumentAsync({ copyToCacheDirectory: true })
}
