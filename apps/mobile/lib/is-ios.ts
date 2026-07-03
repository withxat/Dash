import { Platform } from 'react-native'

/** True when running on iOS — use native SwiftUI-backed controls from `@expo/ui`. */
export const isIOS = Platform.OS === 'ios'
