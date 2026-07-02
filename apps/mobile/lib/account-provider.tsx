import type { ReactNode } from 'react'

import type { AccountContextValue } from './account-context'

import { useQuery } from '@tanstack/react-query'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { AccountContext } from './account-context'
import { cloudflareClient } from './api'
import { getActiveAccountId, setActiveAccount } from './storage'
import { useAuth } from './use-auth'

export function AccountProvider({ children }: { children: ReactNode }) {
	const { status } = useAuth()
	const [selectedAccountId, setSelectedAccountId] = useState<null | string>(null)
	const accountsQuery = useQuery({
		enabled: status === 'authenticated',
		queryFn: () => cloudflareClient.listAccounts(),
		queryKey: ['cf', 'accounts'],
	})
	const accounts = useMemo(() => accountsQuery.data ?? [], [accountsQuery.data])
	const { error, isLoading, isSuccess, refetch } = accountsQuery

	useEffect(() => {
		if (!isSuccess)
			return

		let cancelled = false
		void (async () => {
			const persistedId = await getActiveAccountId()
			const nextId = accounts.some(account => account.id === persistedId)
				? persistedId
				: (accounts[0]?.id ?? null)

			if (cancelled)
				return

			setSelectedAccountId(nextId)
			await setActiveAccount(nextId)
		})()

		return () => {
			cancelled = true
		}
	}, [accounts, isSuccess])

	const setActiveAccountId = useCallback((id: string) => {
		if (!accounts.some(account => account.id === id))
			return
		setSelectedAccountId(id)
		void setActiveAccount(id)
	}, [accounts])

	const activeAccount = accounts.find(account => account.id === selectedAccountId) ?? null
	const value = useMemo<AccountContextValue>(() => ({
		accounts,
		activeAccount,
		activeAccountId: selectedAccountId,
		error,
		isLoading,
		refetch: () => {
			void refetch()
		},
		setActiveAccountId,
	}), [
		accounts,
		activeAccount,
		error,
		isLoading,
		refetch,
		selectedAccountId,
		setActiveAccountId,
	])

	return <AccountContext value={value}>{children}</AccountContext>
}
