import { ApiError } from '@cloudfx/api'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { router } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, View } from 'react-native'

import { AccountSwitcher } from '../../../components/account-switcher'
import { EmptyState } from '../../../components/empty-state'
import { ListSurface, Row } from '../../../components/row'
import { Segmented } from '../../../components/segmented'
import { Skeleton } from '../../../components/skeleton'
import { cloudflareClient } from '../../../lib/api'
import { timeAgo } from '../../../lib/format'
import { useTheme } from '../../../lib/theme'
import { useActiveAccount } from '../../../lib/use-active-account'
import { useTabScrollPadding } from '../../../lib/use-tab-scroll-padding'

type Section = 'pages' | 'workers'

const SECTION_OPTIONS: Array<{ label: string, value: Section }> = [
	{ label: 'Workers', value: 'workers' },
	{ label: 'Pages', value: 'pages' },
]

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function WorkersScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const queryClient = useQueryClient()
	const [section, setSection] = useState<Section>('workers')
	const [refreshing, setRefreshing] = useState(false)

	const workersQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listWorkers(activeAccountId!),
		queryKey: ['cf', 'workers', activeAccountId],
		retry: false,
	})
	const pagesQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listPagesProjects(activeAccountId!),
		queryKey: ['cf', 'pages-projects', activeAccountId],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await Promise.allSettled([
			queryClient.refetchQueries({ queryKey: ['cf', 'workers', activeAccountId] }),
			queryClient.refetchQueries({ queryKey: ['cf', 'pages-projects', activeAccountId] }),
		])
		setRefreshing(false)
	}, [activeAccountId, queryClient])

	const workers = workersQuery.data ?? []
	const projects = pagesQuery.data ?? []

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<AccountSwitcher />

			<Segmented onChange={setSection} options={SECTION_OPTIONS} value={section} />

			{section === 'workers'
				? (
						<ListSurface>
							{!activeAccountId || workersQuery.isLoading
								? (
										<View className="gap-3 py-3">
											<Skeleton className="h-10 w-full" />
											<Skeleton className="h-10 w-full" />
										</View>
									)
								: workersQuery.isError
									? (
											<EmptyState onAction={() => void workersQuery.refetch()}>
												{isForbidden(workersQuery.error)
													? 'Needs the Workers Scripts scope — enable it on your OAuth client and sign in again.'
													: 'Failed to load Workers.'}
											</EmptyState>
										)
									: workers.length === 0
										? <EmptyState>No Workers in this account.</EmptyState>
										: workers.map((worker) => {
												const id = worker.id ?? '—'
												return (
													<Row
														key={id}
														onPress={() => router.push(`/workers/${encodeURIComponent(id)}`)}
														subtitle={worker.modified_on ? `Updated ${timeAgo(worker.modified_on)}` : undefined}
														title={id}
													/>
												)
											})}
						</ListSurface>
					)
				: (
						<ListSurface>
							{!activeAccountId || pagesQuery.isLoading
								? (
										<View className="gap-3 py-3">
											<Skeleton className="h-10 w-full" />
											<Skeleton className="h-10 w-full" />
										</View>
									)
								: pagesQuery.isError
									? (
											<EmptyState onAction={() => void pagesQuery.refetch()}>
												{isForbidden(pagesQuery.error)
													? 'Needs the Pages Read scope — enable it on your OAuth client and sign in again.'
													: 'Failed to load Pages projects.'}
											</EmptyState>
										)
									: projects.length === 0
										? <EmptyState>No Pages projects in this account.</EmptyState>
										: projects.map(project => (
												<Row
													key={project.name}
													onPress={() => router.push(`/workers/pages/${encodeURIComponent(project.name)}`)}
													right={project.production_branch}
													subtitle={project.subdomain}
													title={project.name}
												/>
											))}
						</ListSurface>
					)}
		</ScrollView>
	)
}
