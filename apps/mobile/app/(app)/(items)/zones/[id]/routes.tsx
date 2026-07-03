import { ApiError } from '@cloudfx/api'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useCallback, useState } from 'react'
import { Alert, Pressable, RefreshControl, ScrollView, Text, View } from 'react-native'

import { Badge } from '../../../../../components/badge'
import { Button, ButtonText } from '../../../../../components/button'
import { Card } from '../../../../../components/card'
import { EmptyState } from '../../../../../components/empty-state'
import { TrashIcon } from '../../../../../components/icons'
import { Input } from '../../../../../components/input'
import { SectionLabel } from '../../../../../components/section-label'
import { Skeleton } from '../../../../../components/skeleton'
import { cloudflareClient } from '../../../../../lib/api'
import { cx } from '../../../../../lib/cx'
import { hapticError, hapticSuccess } from '../../../../../lib/haptics'
import { useTheme } from '../../../../../lib/theme'
import { useTabScrollPadding } from '../../../../../lib/use-tab-scroll-padding'
import { useToast } from '../../../../../lib/use-toast'

/** True when the error is a Cloudflare permission failure (missing scope). */
function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}

export default function WorkerRoutesScreen() {
	const tabScrollPadding = useTabScrollPadding()
	const { id } = useLocalSearchParams<{ id: string }>()
	const theme = useTheme()
	const toast = useToast()
	const queryClient = useQueryClient()
	const [pattern, setPattern] = useState('')
	const [script, setScript] = useState('')
	// Route id currently being edited; null = creating a new route.
	const [editingId, setEditingId] = useState<null | string>(null)

	const routesQuery = useQuery({
		enabled: Boolean(id),
		queryFn: () => cloudflareClient.listWorkerRoutes(id),
		queryKey: ['cf', 'zone', id, 'worker-routes'],
		retry: false,
	})

	const invalidate = useCallback(() => {
		void queryClient.invalidateQueries({ queryKey: ['cf', 'zone', id, 'worker-routes'] })
	}, [id, queryClient])

	const resetForm = useCallback(() => {
		setPattern('')
		setScript('')
		setEditingId(null)
	}, [])

	const saveMutation = useMutation({
		mutationFn: (input: { pattern: string, routeId: null | string, script?: string }) =>
			input.routeId
				? cloudflareClient.updateWorkerRoute(id, input.routeId, { pattern: input.pattern, script: input.script })
				: cloudflareClient.createWorkerRoute(id, { pattern: input.pattern, script: input.script }),
		onError: (error) => {
			hapticError()
			toast.show(
				isForbidden(error) ? 'Missing permission — enable the Workers Routes write scope and sign in again.' : 'Failed to save the route.',
				'error',
			)
		},
		onSuccess: (_, input) => {
			hapticSuccess()
			toast.show(input.routeId ? 'Route updated.' : 'Route added.', 'success')
			resetForm()
			invalidate()
		},
	})

	const deleteMutation = useMutation({
		mutationFn: (routeId: string) => cloudflareClient.deleteWorkerRoute(id, routeId),
		onError: () => {
			hapticError()
			toast.show('Failed to delete the route.', 'error')
		},
		onSuccess: (_, routeId) => {
			hapticSuccess()
			toast.show('Route deleted.', 'success')
			if (routeId === editingId)
				resetForm()
			invalidate()
		},
	})

	const saveRoute = useCallback(() => {
		const trimmedPattern = pattern.trim()
		if (!trimmedPattern)
			return
		const trimmedScript = script.trim()
		saveMutation.mutate({
			pattern: trimmedPattern,
			routeId: editingId,
			...(trimmedScript ? { script: trimmedScript } : {}),
		})
	}, [editingId, pattern, saveMutation, script])

	const startEditing = useCallback((routeId: string, routePattern: string, routeScript?: string) => {
		setEditingId(routeId)
		setPattern(routePattern)
		setScript(routeScript ?? '')
	}, [])

	const confirmDelete = useCallback((routeId: string, routePattern: string) => {
		Alert.alert('Delete route?', routePattern, [
			{ style: 'cancel', text: 'Cancel' },
			{ onPress: () => deleteMutation.mutate(routeId), style: 'destructive', text: 'Delete' },
		])
	}, [deleteMutation])

	const routes = routesQuery.data ?? []

	return (
		<ScrollView
			refreshControl={(
				<RefreshControl
					onRefresh={() => void routesQuery.refetch()}
					refreshing={routesQuery.isRefetching}
					tintColor={theme.subtle}
				/>
			)}
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16, paddingBottom: tabScrollPadding }}
			contentInsetAdjustmentBehavior="automatic"
			keyboardShouldPersistTaps="handled"
		>
			<View className="gap-2">
				<SectionLabel>{editingId ? 'Edit route' : 'Add route'}</SectionLabel>
				<Card>
					<View className="gap-3">
						<Input
							autoCapitalize="none"
							autoCorrect={false}
							label="Pattern"
							onChangeText={setPattern}
							placeholder="example.com/*"
							value={pattern}
							mono
						/>
						<Input
							autoCapitalize="none"
							autoCorrect={false}
							label="Worker script (empty to disable the route)"
							onChangeText={setScript}
							placeholder="my-worker"
							value={script}
							mono
						/>
						<Button disabled={!pattern.trim()} loading={saveMutation.isPending} onPress={saveRoute}>
							<ButtonText>{editingId ? 'Save changes' : 'Add route'}</ButtonText>
						</Button>
						{editingId
							? (
									<Button onPress={resetForm} variant="ghost">
										<ButtonText>Cancel editing</ButtonText>
									</Button>
								)
							: null}
					</View>
				</Card>
			</View>

			<View className="gap-2">
				<SectionLabel>Routes</SectionLabel>
				<Card>
					{routesQuery.isLoading
						? (
								<View className="gap-3">
									<Skeleton className="h-8 w-full" />
									<Skeleton className="h-8 w-full" />
								</View>
							)
						: routesQuery.isError
							? (
									<EmptyState onAction={() => void routesQuery.refetch()}>
										{isForbidden(routesQuery.error)
											? 'Needs the Workers Routes scopes — enable them on your OAuth client and sign in again.'
											: 'Failed to load routes.'}
									</EmptyState>
								)
							: routes.length === 0
								? <EmptyState>No Workers routes on this zone.</EmptyState>
								: (
										<View className="gap-4">
											{routes.map(route => (
												<View className="flex-row items-center gap-3" key={route.id}>
													<Pressable
														className={cx(
															`
																min-w-0 flex-1 gap-1 rounded-kumo
																active:opacity-70
															`,
															route.id === editingId && 'opacity-60',
														)}
														accessibilityLabel={`Edit route ${route.pattern}`}
														accessibilityRole="button"
														onPress={() => startEditing(route.id, route.pattern, route.script)}
													>
														<Text className="font-mono text-sm text-default" numberOfLines={1}>
															{route.pattern}
														</Text>
														{route.script
															? <Badge variant="info" mono>{route.script}</Badge>
															: <Badge variant="secondary">disabled</Badge>}
													</Pressable>
													<Pressable
														className="
															rounded-kumo p-2
															active:bg-elevated
														"
														accessibilityLabel={`Delete route ${route.pattern}`}
														hitSlop={8}
														onPress={() => confirmDelete(route.id, route.pattern)}
													>
														<TrashIcon color={theme.danger} size={18} />
													</Pressable>
												</View>
											))}
											<Text className="text-[11px] text-placeholder">Tap a route to edit it in place.</Text>
										</View>
									)}
				</Card>
			</View>
		</ScrollView>
	)
}
