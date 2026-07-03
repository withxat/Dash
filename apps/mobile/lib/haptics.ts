import * as Haptics from 'expo-haptics'

/** Best-effort haptic feedback — failures (e.g. web, simulators) are ignored. */

export function hapticSuccess() {
	Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {})
}

export function hapticError() {
	Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error).catch(() => {})
}

export function hapticLight() {
	Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {})
}
