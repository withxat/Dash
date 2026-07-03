import { useQueryClient } from '@tanstack/react-query'
import { useFocusEffect } from 'expo-router'
import { useCallback } from 'react'

import { getFrequentItemIds, getRecentItemIds } from './home-shortcuts'

/** Silently refresh home list caches when the tab regains focus (no loading skeleton flash). */
export function useHomeListFocusRefresh() {
	const queryClient = useQueryClient()

	useFocusEffect(useCallback(() => {
		void (async () => {
			const [recent, frequent] = await Promise.all([
				getRecentItemIds(),
				getFrequentItemIds(),
			])
			queryClient.setQueryData(['app', 'recent-items'], recent)
			queryClient.setQueryData(['app', 'frequent-items'], frequent)
		})()
	}, [queryClient]))
}
