import type { ComponentType } from 'react'

import type { AppCatalogIcon } from '../lib/app-catalog'
import type { ThemePalette } from '../lib/theme'

import { Chart2 } from '@solar-icons/react-native/category/business/BoldDuotone/Chart2'
import { CodeSquare } from '@solar-icons/react-native/category/it/BoldDuotone/CodeSquare'
import { Structure } from '@solar-icons/react-native/category/it/BoldDuotone/Structure'
import { BranchingPathsUp } from '@solar-icons/react-native/category/map/BoldDuotone/BranchingPathsUp'
import { Global } from '@solar-icons/react-native/category/map/BoldDuotone/Global'
import { Globus } from '@solar-icons/react-native/category/map/BoldDuotone/Globus'
import { Routing } from '@solar-icons/react-native/category/map/BoldDuotone/Routing'
import { Inbox } from '@solar-icons/react-native/category/messages/BoldDuotone/Inbox'
import { Letter } from '@solar-icons/react-native/category/messages/BoldDuotone/Letter'
import { KeyMinimalistic } from '@solar-icons/react-native/category/security/BoldDuotone/KeyMinimalistic'
import { LockKeyhole } from '@solar-icons/react-native/category/security/BoldDuotone/LockKeyhole'
import { ShieldCheck } from '@solar-icons/react-native/category/security/BoldDuotone/ShieldCheck'
import { ShieldUser } from '@solar-icons/react-native/category/security/BoldDuotone/ShieldUser'
import { SettingsMinimalistic } from '@solar-icons/react-native/category/settings/BoldDuotone/SettingsMinimalistic'
import { BoxMinimalistic } from '@solar-icons/react-native/category/ui/BoldDuotone/BoxMinimalistic'
import { Database } from '@solar-icons/react-native/category/ui/BoldDuotone/Database'
import { Gallery } from '@solar-icons/react-native/category/video/BoldDuotone/Gallery'
import { VideoLibrary } from '@solar-icons/react-native/category/video/BoldDuotone/VideoLibrary'
import { View } from 'react-native'

import { cx } from '../lib/cx'
import { useTheme } from '../lib/theme'

interface CatalogItemIconProps {
	icon: AppCatalogIcon
	size?: number
	/** `header` — compact glyph beside native stack inline titles. */
	variant?: 'header' | 'list'
}

type IconTone = keyof Pick<ThemePalette, 'accent' | 'brand' | 'success' | 'warning'>

interface SolarGlyphProps {
	color: string
	size?: number
}

const TONE_CLASSES: Record<IconTone, string> = {
	accent: 'bg-accent/15',
	brand: 'bg-brand/15',
	success: 'bg-success/15',
	warning: 'bg-warning/15',
}

/** Solar Bold Duotone glyph + tint for each catalog entry. */
const CATALOG_ICONS: Record<AppCatalogIcon, { Glyph: ComponentType<SolarGlyphProps>, tone: IconTone }> = {
	access: { Glyph: ShieldUser, tone: 'brand' },
	account: { Glyph: SettingsMinimalistic, tone: 'brand' },
	analytics: { Glyph: Chart2, tone: 'warning' },
	d1: { Glyph: Database, tone: 'accent' },
	email: { Glyph: Letter, tone: 'brand' },
	images: { Glyph: Gallery, tone: 'warning' },
	kv: { Glyph: KeyMinimalistic, tone: 'accent' },
	lb: { Glyph: BranchingPathsUp, tone: 'success' },
	queues: { Glyph: Inbox, tone: 'accent' },
	r2: { Glyph: BoxMinimalistic, tone: 'accent' },
	registrar: { Glyph: Globus, tone: 'success' },
	secrets: { Glyph: LockKeyhole, tone: 'warning' },
	stream: { Glyph: VideoLibrary, tone: 'warning' },
	tunnels: { Glyph: Routing, tone: 'success' },
	turnstile: { Glyph: ShieldCheck, tone: 'brand' },
	vectorize: { Glyph: Structure, tone: 'accent' },
	workers: { Glyph: CodeSquare, tone: 'brand' },
	zones: { Glyph: Global, tone: 'success' },
}

export function CatalogItemIcon({ icon, size, variant = 'list' }: CatalogItemIconProps) {
	const theme = useTheme()
	const { Glyph, tone } = CATALOG_ICONS[icon]
	const glyphSize = size ?? (variant === 'header' ? 18 : 28)

	return (
		<View
			className={cx(
				'items-center justify-center',
				variant === 'header' ? 'size-7 rounded-lg' : 'size-11 rounded-xl',
				TONE_CLASSES[tone],
			)}
			style={{ borderCurve: 'continuous' }}
		>
			<Glyph color={theme[tone]} size={glyphSize} />
		</View>
	)
}
