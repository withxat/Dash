import type { ComponentType, CSSProperties } from 'react'

import arrowRight from '../../../ios/Dash/Resources/Assets.xcassets/SolarAltArrowRightOutline.imageset/SolarAltArrowRightOutline.svg'
import chartOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarChart2Outline.imageset/SolarChart2Outline.svg'
import cloudFill from '../../../ios/Dash/Resources/Assets.xcassets/SolarCloudFill.imageset/SolarCloudFill.svg'
import cloudOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarCloudOutline.imageset/SolarCloudOutline.svg'
import cloudStorageFill from '../../../ios/Dash/Resources/Assets.xcassets/SolarCloudStorageFill.imageset/SolarCloudStorageFill.svg'
import codeOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarCodeOutline.imageset/SolarCodeOutline.svg'
import codeSquareFill from '../../../ios/Dash/Resources/Assets.xcassets/SolarCodeSquareFill.imageset/SolarCodeSquareFill.svg'
import databaseFill from '../../../ios/Dash/Resources/Assets.xcassets/SolarDatabaseFill.imageset/SolarDatabaseFill.svg'
import globalFill from '../../../ios/Dash/Resources/Assets.xcassets/SolarGlobalFill.imageset/SolarGlobalFill.svg'
import globalOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarGlobalOutline.imageset/SolarGlobalOutline.svg'
import lockOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarLockKeyholeOutline.imageset/SolarLockKeyholeOutline.svg'
import tabFeaturesOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarTabFeaturesLine.imageset/SolarTabFeaturesLine.svg'
import tabHomeFill from '../../../ios/Dash/Resources/Assets.xcassets/SolarTabHomeFill.imageset/SolarTabHomeFill.svg'
import tabWatchtowerOutline from '../../../ios/Dash/Resources/Assets.xcassets/SolarTabWatchtowerLine.imageset/SolarTabWatchtowerLine.svg'

export interface SolarIconProps {
	'aria-hidden'?: boolean
	'className'?: string
	'size'?: number | string
	'weight'?: 'fill' | 'regular'
}

export type SolarIconComponent = ComponentType<SolarIconProps>

function createSolarIcon(
	outlineUrl: string,
	fillUrl: string = outlineUrl,
): SolarIconComponent {
	return function SolarIcon({
		'aria-hidden': ariaHidden,
		className,
		size = 24,
		weight = 'regular',
	}) {
		const maskUrl = weight === 'fill' ? fillUrl : outlineUrl
		const style: CSSProperties = {
			backgroundColor: 'currentColor',
			blockSize: size,
			display: 'inline-block',
			flex: 'none',
			inlineSize: size,
			maskImage: `url("${maskUrl}")`,
			maskPosition: 'center',
			maskRepeat: 'no-repeat',
			maskSize: 'contain',
			WebkitMaskImage: `url("${maskUrl}")`,
			WebkitMaskPosition: 'center',
			WebkitMaskRepeat: 'no-repeat',
			WebkitMaskSize: 'contain',
		}

		return (
			<span
				aria-hidden={ariaHidden ?? true}
				className={className}
				style={style}
			/>
		)
	}
}

export const SolarArrowRightIcon = createSolarIcon(arrowRight)
export const SolarChartIcon = createSolarIcon(chartOutline)
export const SolarCloudIcon = createSolarIcon(cloudOutline, cloudFill)
export const SolarCloudStorageIcon = createSolarIcon(cloudStorageFill)
export const SolarCodeIcon = createSolarIcon(codeOutline, codeSquareFill)
export const SolarDatabaseIcon = createSolarIcon(databaseFill)
export const SolarGlobalIcon = createSolarIcon(globalOutline, globalFill)
export const SolarLockIcon = createSolarIcon(lockOutline)
export const SolarTabFeaturesIcon = createSolarIcon(tabFeaturesOutline)
export const SolarTabHomeIcon = createSolarIcon(tabHomeFill, tabHomeFill)
export const SolarTabWatchtowerIcon = createSolarIcon(tabWatchtowerOutline)
