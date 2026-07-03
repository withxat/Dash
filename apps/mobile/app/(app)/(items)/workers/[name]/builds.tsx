import type { WorkersBuild } from '@cloudfx/api'

import type { BadgeTone } from '../../../../../components/badge'

import { useQuery } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { RefreshControl, ScrollView, Text } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { QuerySection } from '../../../../../components/query-section'
import { ListGroup, Row } from '../../../../../components/row'
import { cloudflareClient } from '../../../../../lib/api'
import { timeAgo } from '../../../../../lib/format'
import { useTheme } from '../../../../../lib/theme'
import { useActiveAccount } from '../../../../../lib/use-active-account'

function buildTone(build: WorkersBuild): BadgeTone {
	if (build.build_outcome === 'success')
		return 'success'
	if (build.build_outcome === 'fail')
		return 'error'
	if (build.status === 'running' || build.status === 'queued' || build.status === 'initializing')
		return 'warning'
	return 'secondary'
}

function buildLabel(build: WorkersBuild): string {
	return build.build_outcome ?? build.status ?? 'unknown'
}

function buildSubtitle(build: WorkersBuild): string | undefined {
	const meta = build.build_trigger_metadata
	const commit = meta?.commit_hash?.slice(0, 7)
	const parts = [meta?.branch, commit, meta?.commit_message].filter((part): part is string => Boolean(part))
	return parts.length > 0 ? parts.join(' · ') : undefined
}

export default function WorkerBuildsScreen() {
	const { name } = useLocalSearchParams<{ name: string }>()
	const { activeAccountId } = useActiveAccount()
	const theme = useTheme()
	const [refreshing, setRefreshing] = useState(false)

	// Builds are keyed by the script's system-generated tag, not its name.
	const scriptsQuery = useQuery({
		enabled: Boolean(activeAccountId),
		queryFn: () => cloudflareClient.listWorkers(activeAccountId!),
		queryKey: ['cf', 'workers', activeAccountId],
		retry: false,
	})
	const scriptTag = scriptsQuery.data?.find(script => script.id === name)?.tag

	const buildsQuery = useQuery({
		enabled: Boolean(activeAccountId && scriptTag),
		queryFn: () => cloudflareClient.listWorkerBuilds(activeAccountId!, scriptTag!, { perPage: 25 }),
		queryKey: ['cf', 'worker-builds', activeAccountId, scriptTag],
		retry: false,
	})

	const onRefresh = useCallback(async () => {
		setRefreshing(true)
		await buildsQuery.refetch().catch(() => {})
		setRefreshing(false)
	}, [buildsQuery])

	const tagMissing = scriptsQuery.isSuccess && !scriptTag

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			contentInsetAdjustmentBehavior="automatic"
			refreshControl={<RefreshControl onRefresh={onRefresh} refreshing={refreshing} tintColor={theme.subtle} />}
		>
			<ListGroup title="Build history">
				{tagMissing
					? <Text className="py-4 text-center text-sm text-subtle">Could not resolve this Worker's script tag.</Text>
					: (
							<QuerySection
								renderItem={build => (
									<Row
										chevron={false}
										right={<Badge variant={buildTone(build)}>{buildLabel(build)}</Badge>}
										subtitle={buildSubtitle(build)}
										title={timeAgo(build.created_on)}
									/>
								)}
								emptyText="No builds yet — connect this Worker to a Git repository to use Workers Builds."
								error={buildsQuery.error ?? scriptsQuery.error}
								errorText="Failed to load builds."
								isError={buildsQuery.isError || scriptsQuery.isError}
								isLoading={!activeAccountId || scriptsQuery.isLoading || buildsQuery.isLoading}
								items={buildsQuery.data}
								onRetry={() => void buildsQuery.refetch()}
								scopeHint="Needs the Workers Builds read scope — enable it on your OAuth client and sign in again."
							/>
						)}
			</ListGroup>
		</ScrollView>
	)
}
