import type { AccountContextValue } from './account-context'

import { use } from 'react'

import { AccountContext } from './account-context'

export function useActiveAccount(): AccountContextValue {
	const ctx = use(AccountContext)
	if (!ctx)
		throw new Error('useActiveAccount must be used within an AccountProvider')
	return ctx
}
