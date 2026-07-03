import { AltArrowLeft } from '@solar-icons/react-native/category/arrows/Linear/AltArrowLeft'
import { AltArrowRight } from '@solar-icons/react-native/category/arrows/Linear/AltArrowRight'
import { Code2 } from '@solar-icons/react-native/category/it/Linear/Code2'
import { Global } from '@solar-icons/react-native/category/map/Linear/Global'
import { Pen } from '@solar-icons/react-native/category/messages/Linear/Pen'
import { Unread } from '@solar-icons/react-native/category/messages/Linear/Unread'
import { Magnifier } from '@solar-icons/react-native/category/search/Linear/Magnifier'
import { Shield } from '@solar-icons/react-native/category/security/Linear/Shield'
import { Bolt } from '@solar-icons/react-native/category/ui/Linear/Bolt'
import { DangerTriangle } from '@solar-icons/react-native/category/ui/Linear/DangerTriangle'
import { TrashBinMinimalistic } from '@solar-icons/react-native/category/ui/Linear/TrashBinMinimalistic'
import Svg, { Path } from 'react-native-svg'

interface IconProps {
	color: string
	size?: number
	strokeWidth?: number
}

interface StrokeIconProps extends IconProps {
	paths: string[]
}

/** Stroke-based 24×24 glyph for shapes Solar doesn't ship (plus, x, caret pair). */
function StrokeIcon({ color, paths, size = 20, strokeWidth = 2 }: StrokeIconProps) {
	return (
		<Svg fill="none" height={size} viewBox="0 0 24 24" width={size}>
			{paths.map(d => (
				<Path
					d={d}
					key={d}
					stroke={color}
					strokeLinecap="round"
					strokeLinejoin="round"
					strokeWidth={strokeWidth}
				/>
			))}
		</Svg>
	)
}

export function ChevronLeftIcon({ color, size = 20 }: IconProps) {
	return <AltArrowLeft color={color} size={size} />
}

export function ChevronRightIcon({ color, size = 20 }: IconProps) {
	return <AltArrowRight color={color} size={size} />
}

export function CaretUpDownIcon({ color, size = 16, strokeWidth = 2 }: IconProps) {
	return (
		<StrokeIcon
			color={color}
			paths={['M7 9.25 12 4.75l5 4.5', 'M7 14.75l5 4.5 5-4.5']}
			size={size}
			strokeWidth={strokeWidth}
		/>
	)
}

export function CheckIcon({ color, size = 20 }: IconProps) {
	return <Unread color={color} size={size} />
}

export function PlusIcon(props: IconProps) {
	return <StrokeIcon {...props} paths={['M5 12h14', 'M12 5v14']} />
}

export function TrashIcon({ color, size = 20 }: IconProps) {
	return <TrashBinMinimalistic color={color} size={size} />
}

export function ShieldIcon({ color, size = 20 }: IconProps) {
	return <Shield color={color} size={size} />
}

export function ZapIcon({ color, size = 20 }: IconProps) {
	return <Bolt color={color} size={size} />
}

export function GlobeIcon({ color, size = 20 }: IconProps) {
	return <Global color={color} size={size} />
}

export function CodeIcon({ color, size = 20 }: IconProps) {
	return <Code2 color={color} size={size} />
}

export function AlertTriangleIcon({ color, size = 20 }: IconProps) {
	return <DangerTriangle color={color} size={size} />
}

export function PencilIcon({ color, size = 20 }: IconProps) {
	return <Pen color={color} size={size} />
}

export function SearchIcon({ color, size = 20 }: IconProps) {
	return <Magnifier color={color} size={size} />
}

export function XIcon(props: IconProps) {
	return <StrokeIcon {...props} paths={['M18 6 6 18', 'm6 6 12 12']} />
}
