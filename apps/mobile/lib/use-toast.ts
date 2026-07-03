import type { ToastContextValue } from './toast-context'

import { use } from 'react'

import { ToastContext } from './toast-context'

export function useToast(): ToastContextValue {
	const ctx = use(ToastContext)
	if (!ctx)
		throw new Error('useToast must be used inside ToastProvider')
	return ctx
}
