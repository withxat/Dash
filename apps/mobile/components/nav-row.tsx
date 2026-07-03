import type { ReactNode } from 'react'
import type { PressableProps } from 'react-native'

import { Children, Fragment, isValidElement } from 'react'
import { Pressable, Text, View } from 'react-native'

import { cx } from '../lib/cx'
import { chillFonts } from '../lib/fonts'
import { useTheme } from '../lib/theme'
import { Card } from './card'
import { ChevronRightIcon } from './icons'
import { SectionLabel } from './section-label'

/** Horizontal rule between grouped list rows — never use border utilities on rows. */
export function ListDivider() {
	return <View className="h-px bg-hairline" />
}

function withListDividers(children: ReactNode) {
	const items = Children.toArray(children).filter(child => child != null)

	return items.map((child, index) => (
		// eslint-disable-next-line react/no-array-index-key -- divider slots follow child order
		<Fragment key={isValidElement(child) && child.key != null ? child.key : index}>
			{child}
			{index < items.length - 1 ? <ListDivider /> : null}
		</Fragment>
	))
}

interface ListSurfaceProps {
	children: ReactNode
	className?: string
}

/** Inset grouped list container — outer ring only; row dividers are separate Views. */
export function ListSurface({ children, className }: ListSurfaceProps) {
	return (
		<Card className={cx('overflow-hidden rounded-kumo bg-base px-4 py-0', className)} shadow={false}>
			{withListDividers(children)}
		</Card>
	)
}

interface NavRowProps extends Omit<PressableProps, 'children'> {
	/** Show a trailing chevron. Defaults to true. */
	chevron?: boolean
	/** Optional leading content (e.g. an icon). */
	leading?: ReactNode
	/** Optional right-aligned content (a string or e.g. a Badge). */
	right?: ReactNode
	/** Optional secondary line under the title. */
	subtitle?: string
	/** Main title line. */
	title: string
}

/** A pressable list row: title + subtitle on the left, meta + chevron on the right. */
export function NavRow({
	chevron = true,
	className,
	leading,
	right,
	subtitle,
	title,
	...props
}: NavRowProps) {
	const theme = useTheme()

	return (
		<Pressable
			className={cx(
				`
					flex-row items-center justify-between py-3
					active:opacity-70
				`,
				className,
			)}
			accessibilityRole="button"
			{...props}
		>
			{leading ? <View className="mr-3">{leading}</View> : null}
			<View className="min-w-0 flex-1 gap-0.5">
				<Text className="text-default" numberOfLines={1} style={{ fontFamily: chillFonts.medium }}>
					{title}
				</Text>
				{subtitle
					? (
							<Text className="text-xs text-subtle" numberOfLines={1}>
								{subtitle}
							</Text>
						)
					: null}
			</View>
			{typeof right === 'string'
				? (
						<Text className="ml-3 text-xs text-subtle" numberOfLines={1}>
							{right}
						</Text>
					)
				: right
					? <View className="ml-3">{right}</View>
					: null}
			{chevron
				? (
						<View className="ml-2">
							<ChevronRightIcon color={theme.placeholder} size={16} />
						</View>
					)
				: null}
		</Pressable>
	)
}

interface ListGroupProps {
	children: ReactNode
	title?: string
}

/** Grouped list section with a section label. */
export function ListGroup({ children, title }: ListGroupProps) {
	return (
		<View className="gap-2">
			{title ? <SectionLabel>{title}</SectionLabel> : null}
			<ListSurface>{children}</ListSurface>
		</View>
	)
}
