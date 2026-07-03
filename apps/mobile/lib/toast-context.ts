import { createContext } from 'react'

export type ToastTone = 'error' | 'neutral' | 'success'

export interface ToastContextValue {
	show: (message: string, tone?: ToastTone) => void
}

export const ToastContext = createContext<null | ToastContextValue>(null)
