import type { AuthContextValue } from './auth-context'

import { use } from 'react'

import { AuthContext } from './auth-context'

export function useAuth(): AuthContextValue {
	const ctx = use(AuthContext)
	if (!ctx)
		throw new Error('useAuth must be used within an AuthProvider')
	return ctx
}
