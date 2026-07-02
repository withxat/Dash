import type { CloudflareAccount } from '@cloudfx/api'

import { createContext } from 'react'

export interface AccountContextValue {
	accounts: CloudflareAccount[]
	activeAccount: CloudflareAccount | null
	activeAccountId: null | string
	error: Error | null
	isLoading: boolean
	refetch: () => void
	setActiveAccountId: (id: string) => void
}

export const AccountContext = createContext<AccountContextValue | null>(null)
