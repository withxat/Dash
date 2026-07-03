import type { ReactNode } from 'react'

import { Text, View } from 'react-native'

import { cn } from './cn'

export interface TableColumn<T> {
	key: string
	label: string
	render?: (row: T) => ReactNode
	width?: `${number}%` | number
}

interface TableProps<T> {
	className?: string
	columns: Array<TableColumn<T>>
	data: T[]
	keyExtractor: (row: T, index: number) => string
}

/** Kumo Table — simplified row/column layout for mobile. */
export function Table<T>({ className, columns, data, keyExtractor }: TableProps<T>) {
	return (
		<View className={cn('overflow-hidden rounded-kumo border border-line', className)}>
			<View className="flex-row border-b border-hairline bg-elevated px-3 py-2">
				{columns.map(column => (
					<View className="flex-1" key={column.key} style={column.width ? { flex: 0, width: column.width } : undefined}>
						<Text className="text-xs font-semibold uppercase text-subtle">{column.label}</Text>
					</View>
				))}
			</View>
			{data.map((row, index) => (
				<View
					className="
						flex-row border-b border-hairline px-3 py-3
						last:border-b-0
					"
					key={keyExtractor(row, index)}
				>
					{columns.map(column => (
						<View className="flex-1 justify-center" key={column.key} style={column.width ? { flex: 0, width: column.width } : undefined}>
							{column.render
								? column.render(row)
								: (
										<Text className="text-sm text-default">
											{String((row as Record<string, unknown>)[column.key] ?? '')}
										</Text>
									)}
						</View>
					))}
				</View>
			))}
		</View>
	)
}
