import type { D1QueryResult } from '@cloudfx/api'

import { useMutation } from '@tanstack/react-query'
import { useLocalSearchParams } from 'expo-router'
import { useState } from 'react'
import { ScrollView, Text, View } from 'react-native'

import { Button, ButtonText } from '../../../../components/button'
import { Card } from '../../../../components/card'
import { Input } from '../../../../components/input'
import { cloudflareClient } from '../../../../lib/api'
import { isForbidden } from '../../../../lib/api-errors'
import { hapticError } from '../../../../lib/haptics'
import { useActiveAccount } from '../../../../lib/use-active-account'

/** Statement verbs the console will send — reads only, no mutations. */
const READ_ONLY_PREFIXES = ['select', 'pragma', 'explain', 'with']

function isReadOnlySql(sql: string): boolean {
	const head = sql.trim().toLowerCase()
	return READ_ONLY_PREFIXES.some(prefix => head.startsWith(prefix))
}

function formatCell(value: unknown): string {
	if (value == null)
		return 'NULL'
	if (typeof value === 'object')
		return JSON.stringify(value)
	return String(value)
}

export default function D1ConsoleScreen() {
	const { sql: initialSql, uuid } = useLocalSearchParams<{ name?: string, sql?: string, uuid: string }>()
	const { activeAccountId } = useActiveAccount()
	const [sql, setSql] = useState(initialSql ?? '')
	const [error, setError] = useState<null | string>(null)

	const queryMutation = useMutation({
		mutationFn: (statement: string) => cloudflareClient.queryD1Database(activeAccountId!, uuid, statement),
		onError: (err) => {
			hapticError()
			setError(isForbidden(err)
				? 'Needs the D1 read scope — enable it on your OAuth client and sign in again.'
				: err instanceof Error ? err.message : 'Query failed.')
		},
		onMutate: () => setError(null),
	})

	const trimmed = sql.trim()
	const readOnly = isReadOnlySql(trimmed)
	const results = queryMutation.data

	return (
		<ScrollView
			className="flex-1 bg-canvas"
			contentContainerStyle={{ gap: 16, padding: 16 }}
			keyboardShouldPersistTaps="handled"
		>
			<Input
				autoCapitalize="none"
				autoCorrect={false}
				className="min-h-28"
				label="SQL (read-only)"
				onChangeText={setSql}
				placeholder="SELECT * FROM my_table LIMIT 25"
				textAlignVertical="top"
				value={sql}
				mono
				multiline
			/>
			{trimmed && !readOnly
				? (
						<Text className="text-xs text-danger">
							Only SELECT, PRAGMA, EXPLAIN and WITH statements can run here.
						</Text>
					)
				: null}

			<Button
				disabled={!trimmed || !readOnly || !activeAccountId}
				loading={queryMutation.isPending}
				onPress={() => queryMutation.mutate(trimmed)}
			>
				<ButtonText>Run query</ButtonText>
			</Button>

			{error
				? (
						<Card>
							<Text className="font-mono text-xs text-danger" selectable>{error}</Text>
						</Card>
					)
				: null}

			{results?.map((result, index) => (
				// eslint-disable-next-line react/no-array-index-key -- one result set per statement
				<ResultCard key={index} result={result} />
			))}
		</ScrollView>
	)
}

function ResultCard({ result }: { result: D1QueryResult }) {
	const rows = (result.results ?? []) as Array<Record<string, unknown>>
	const meta = result.meta as undefined | { duration?: number, rows_read?: number }

	return (
		<Card>
			<View className="gap-3">
				<Text className="text-xs text-subtle">
					{`${rows.length} row${rows.length === 1 ? '' : 's'}`}
					{meta?.duration != null ? ` · ${meta.duration.toFixed(1)} ms` : ''}
					{meta?.rows_read != null ? ` · ${meta.rows_read} read` : ''}
				</Text>
				{rows.length === 0
					? <Text className="text-sm text-subtle">No rows returned.</Text>
					: rows.slice(0, 50).map((row, rowIndex) => (
							// eslint-disable-next-line react/no-array-index-key -- result rows have no stable id
							<View className="gap-0.5" key={rowIndex}>
								{Object.entries(row).map(([column, value]) => (
									<Text className="font-mono text-xs text-default" key={column} selectable>
										<Text className="text-subtle">{`${column}: `}</Text>
										{formatCell(value)}
									</Text>
								))}
							</View>
						))}
				{rows.length > 50
					? <Text className="text-xs text-subtle">{`Showing first 50 of ${rows.length} rows.`}</Text>
					: null}
			</View>
		</Card>
	)
}
