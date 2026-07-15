#!/usr/bin/env node
/**
 * Generates Solar SVG assets for Dash iOS.
 * - Bold Duotone catalog icons (Items tab)
 * - Linear outline icons (sub-pages + chrome)
 *
 * Run: pnpm ios:icons
 */
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const assetsDir = path.join(__dirname, '../Dash/Resources/Assets.xcassets')
const solarRoot = path.dirname(require.resolve('@solar-icons/react-native/package.json'))

/** @typedef {{ tag: 'path' | 'circle' | 'g', d?: string, cx?: string, cy?: string, r?: string, stroke?: boolean, strokeWidth?: string, strokeLinecap?: string, strokeLinejoin?: string, fillRule?: string, clipRule?: string, opacity?: string, children?: Element[] }} Element */

/** Catalog Bold Duotone icons (Items layer). */
const DUOTONE_CATALOG = {
	SolarGlobal: 'map/BoldDuotone/Global',
	SolarGlobus: 'map/BoldDuotone/Globus',
	SolarMapPoint: 'map/BoldDuotone/MapPoint',
	SolarShieldNetwork: 'security/BoldDuotone/ShieldNetwork',
	SolarCodeSquare: 'it/BoldDuotone/CodeSquare',
	SolarBox: 'ui/BoldDuotone/Box',
	SolarScreencast2: 'it/BoldDuotone/Screencast2',
	SolarHeartPulse: 'medicine/BoldDuotone/HeartPulse',
	SolarCloudStorage: 'devices/BoldDuotone/CloudStorage',
	SolarKeyMinimalistic: 'security/BoldDuotone/KeyMinimalistic',
	SolarDatabase: 'ui/BoldDuotone/Database',
	SolarInbox: 'messages/BoldDuotone/Inbox',
	SolarBolt: 'ui/BoldDuotone/Bolt',
	SolarRoute: 'map/BoldDuotone/Route',
	SolarLockKeyhole: 'security/BoldDuotone/LockKeyhole',
	SolarStructure: 'it/BoldDuotone/Structure',
	SolarInfinite: 'astronomy/BoldDuotone/Infinite',
	SolarCommand: 'it/BoldDuotone/Command',
	SolarShieldCheck: 'security/BoldDuotone/ShieldCheck',
	SolarTuning2: 'settings/BoldDuotone/Tuning2',
	SolarInboxArchive: 'messages/BoldDuotone/InboxArchive',
	SolarBug: 'it/BoldDuotone/Bug',
	SolarShieldKeyhole: 'security/BoldDuotone/ShieldKeyhole',
	SolarShieldUser: 'security/BoldDuotone/ShieldUser',
	SolarUsersGroupRounded: 'users/BoldDuotone/UsersGroupRounded',
	SolarShieldStar: 'security/BoldDuotone/ShieldStar',
	SolarKey: 'security/BoldDuotone/Key',
	SolarShield: 'security/BoldDuotone/Shield',
	SolarGps: 'map/BoldDuotone/Gps',
	SolarRouting: 'map/BoldDuotone/Routing',
	SolarBranchingPathsUp: 'map/BoldDuotone/BranchingPathsUp',
	SolarLockPassword: 'security/BoldDuotone/LockPassword',
	SolarBoltCircle: 'ui/BoldDuotone/BoltCircle',
	SolarLetter: 'messages/BoldDuotone/Letter',
	SolarGallery: 'video/BoldDuotone/Gallery',
	SolarVideoLibrary: 'video/BoldDuotone/VideoLibrary',
	SolarChart2: 'business/BoldDuotone/Chart2',
	SolarExport: 'arrows-action/BoldDuotone/Export',
	SolarUserCircle: 'users/BoldDuotone/UserCircle',
	// Kept for chrome / legacy references outside the feature catalog.
	SolarBoxMinimalistic: 'ui/BoldDuotone/BoxMinimalistic',
	SolarSettingsMinimalistic: 'settings/BoldDuotone/SettingsMinimalistic',
}

/** Catalog + UI Linear outline icons (sub-pages). */
const OUTLINE_ICONS = {
	SolarGlobalOutline: 'map/Linear/Global',
	SolarGlobusOutline: 'map/Linear/Globus',
	SolarMapPointOutline: 'map/Linear/MapPoint',
	SolarShieldNetworkOutline: 'security/Linear/ShieldNetwork',
	SolarCodeSquareOutline: 'it/Linear/CodeSquare',
	SolarBoxOutline: 'ui/Linear/Box',
	SolarScreencast2Outline: 'it/Linear/Screencast2',
	SolarHeartPulseOutline: 'medicine/Linear/HeartPulse',
	SolarCloudStorageOutline: 'devices/Linear/CloudStorage',
	SolarKeyMinimalisticOutline: 'security/Linear/KeyMinimalistic',
	SolarDatabaseOutline: 'ui/Linear/Database',
	SolarInboxOutline: 'messages/Linear/Inbox',
	SolarBoltOutline: 'ui/Linear/Bolt',
	SolarRouteOutline: 'map/Linear/Route',
	SolarLockKeyholeOutline: 'security/Linear/LockKeyhole',
	SolarStructureOutline: 'it/Linear/Structure',
	SolarInfiniteOutline: 'astronomy/Linear/Infinite',
	SolarCommandOutline: 'it/Linear/Command',
	SolarShieldCheckOutline: 'security/Linear/ShieldCheck',
	SolarTuning2Outline: 'settings/Linear/Tuning2',
	SolarInboxArchiveOutline: 'messages/Linear/InboxArchive',
	SolarBugOutline: 'it/Linear/Bug',
	SolarShieldKeyholeOutline: 'security/Linear/ShieldKeyhole',
	SolarShieldUserOutline: 'security/Linear/ShieldUser',
	SolarUsersGroupRoundedOutline: 'users/Linear/UsersGroupRounded',
	SolarShieldStarOutline: 'security/Linear/ShieldStar',
	SolarKeyOutline: 'security/Linear/Key',
	SolarShieldOutline: 'security/Linear/Shield',
	SolarGpsOutline: 'map/Linear/Gps',
	SolarRoutingOutline: 'map/Linear/Routing',
	SolarBranchingPathsUpOutline: 'map/Linear/BranchingPathsUp',
	SolarLockPasswordOutline: 'security/Linear/LockPassword',
	SolarBoltCircleOutline: 'ui/Linear/BoltCircle',
	SolarLetterOutline: 'messages/Linear/Letter',
	SolarGalleryOutline: 'video/Linear/Gallery',
	SolarVideoLibraryOutline: 'video/Linear/VideoLibrary',
	SolarChart2Outline: 'business/Linear/Chart2',
	SolarExportOutline: 'arrows-action/Linear/Export',
	SolarUserCircleOutline: 'users/Linear/UserCircle',
	SolarBoxMinimalisticOutline: 'ui/Linear/BoxMinimalistic',
	SolarSettingsMinimalisticOutline: 'settings/Linear/SettingsMinimalistic',
	SolarAltArrowRightOutline: 'arrows/Linear/AltArrowRight',
	SolarAltArrowLeftOutline: 'arrows/Linear/AltArrowLeft',
	SolarDangerTriangleOutline: 'ui/Linear/DangerTriangle',
	SolarCodeCircleOutline: 'it/Linear/CodeCircle',
	SolarPenOutline: 'messages/Linear/Pen',
	SolarPenNewSquareOutline: 'messages/Linear/PenNewSquare',
	SolarTrashBinOutline: 'ui/Linear/TrashBinMinimalistic',
	SolarCloudOutline: 'weather/Linear/Cloud',
	SolarFileOutline: 'files/Linear/File',
	SolarUploadOutline: 'arrows-action/Linear/Upload',
	SolarUnreadOutline: 'messages/Linear/Unread',
	SolarMagnifierOutline: 'search/Linear/MinimalisticMagnifier',
	SolarCloseCircleOutline: 'ui/Linear/CloseCircle',
	SolarCheckCircleOutline: 'ui/Linear/CheckCircle',
	SolarClockCircleOutline: 'time/Linear/ClockCircle',
	SolarSledgehammerOutline: 'ui/Linear/Sledgehammer',
	SolarSliderHorizontalOutline: 'ui/Linear/SliderMinimalisticHorizontal',
	SolarPinListOutline: 'ui/Linear/PinList',
	SolarPinOutline: 'ui/Linear/Pin',
	SolarPinBold: 'ui/Bold/Pin',
	SolarCheckCircleBold: 'ui/Bold/CheckCircle',
	SolarUsersGroupOutline: 'users/Linear/UsersGroupRounded',
}

/** Simple stroke icons Solar doesn't ship as standalone assets. */
const STROKE_ICONS = {
	SolarPlusOutline: ['M5 12h14', 'M12 5v14'],
	SolarCircleOutline: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z'],
}

/** Hand-tuned bodies that deviate from Solar's linear source. */
const HAND_TUNED_ICONS = {
	// Solar draws menu dots as stroked rings; solid dots read better at 22pt.
	SolarMenuDotsOutline:
		'<circle cx="5" cy="12" r="2" fill="#000"/><circle cx="12" cy="12" r="2" fill="#000"/><circle cx="19" cy="12" r="2" fill="#000"/>',
}

/** @returns {Element[]} */
function extractElements(iconPath) {
	const source = fs.readFileSync(path.join(solarRoot, 'dist/icons', `${iconPath}.mjs`), 'utf8')
	/** @type {Element[]} */
	const elements = []

	for (const match of source.matchAll(/(?:i|a|r)\((r|n|G),\{([^}]*)\}(?:,(\{[^}]*\}))?\)/g)) {
		const attrs = match[2]
		const childBlock = match[3]
		let tagName
		if (match[1] === 'G' || childBlock?.includes('children:['))
			tagName = 'g'
		else if (attrs.includes('d:'))
			tagName = 'path'
		else if (attrs.includes('cx:'))
			tagName = 'circle'
		else
			continue
		const element = /** @type {Element} */ ({
			tag: tagName,
			stroke: attrs.includes('stroke:'),
			strokeWidth: attrs.match(/strokeWidth:`([^`]+)`/)?.[1] ?? '1.5',
			strokeLinecap: attrs.match(/strokeLinecap:`([^`]+)`/)?.[1],
			strokeLinejoin: attrs.match(/strokeLinejoin:`([^`]+)`/)?.[1],
			d: attrs.match(/d:`([^`]+)`/)?.[1],
			cx: attrs.match(/cx:`([^`]+)`/)?.[1],
			cy: attrs.match(/cy:`([^`]+)`/)?.[1],
			r: attrs.match(/r:`([^`]+)`/)?.[1],
			fillRule: attrs.match(/fillRule:`([^`]+)`/)?.[1],
			clipRule: attrs.match(/clipRule:`([^`]+)`/)?.[1],
			opacity: attrs.match(/opacity:`([^`]+)`/)?.[1],
		})

		if (tagName === 'g' && childBlock) {
			element.children = []
			for (const child of childBlock.matchAll(/d:`([^`]+)`/g)) {
				element.children.push({ tag: 'path', d: child[1], stroke: false })
			}
		}

		if (element.tag === 'path' && !element.d)
			continue
		if (element.tag === 'circle' && !(element.cx && element.cy && element.r))
			continue
		elements.push(element)
	}

	if (elements.length === 0)
		throw new Error(`${iconPath}: no drawable elements found`)
	return elements
}

/** @param {Element[]} elements */
function svgFor(elements, { template, strokeWidth }) {
	const body = elements.map((el) => renderElement(el, template, strokeWidth)).join('')
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${body}</svg>`
}

/** @param {Element} el */
function renderElement(el, template, strokeWidth) {
	if (el.tag === 'g') {
		const opacity = el.opacity ? ` opacity="${el.opacity}"` : ''
		const children = (el.children ?? []).map(child => renderElement(child, template, strokeWidth)).join('')
		return `<g${opacity}>${children}</g>`
	}

	if (el.tag === 'circle') {
		const paint = el.stroke
			? `fill="none" stroke="#000" stroke-width="${strokeWidth ?? el.strokeWidth}"`
			: `fill="#000"`
		return `<circle cx="${el.cx}" cy="${el.cy}" r="${el.r}" ${paint}/>`
	}

	const fillRule = el.fillRule ? ` fill-rule="${el.fillRule}"` : ''
	const clipRule = el.clipRule ? ` clip-rule="${el.clipRule}"` : ''
	if (el.stroke) {
		const cap = el.strokeLinecap ? ` stroke-linecap="${el.strokeLinecap}"` : ' stroke-linecap="round"'
		const join = el.strokeLinejoin ? ` stroke-linejoin="${el.strokeLinejoin}"` : ' stroke-linejoin="round"'
		return `<path d="${el.d}" fill="none" stroke="#000" stroke-width="${strokeWidth ?? el.strokeWidth}"${cap}${join}/>`
	}

	const opacity = el.opacity ? ` opacity="${el.opacity}"` : ''
	return `<path d="${el.d}" fill="#000"${fillRule}${clipRule}${opacity}/>`
}

/** @param {string[]} paths */
function strokeSvgFor(paths) {
	const body = paths.map(d =>
		`<path d="${d}" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,
	).join('')
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${body}</svg>`
}

function writeImageset(name, svg, template) {
	const dir = path.join(assetsDir, `${name}.imageset`)
	fs.mkdirSync(dir, { recursive: true })
	const filename = `${name}.svg`
	fs.writeFileSync(path.join(dir, filename), svg)
	fs.writeFileSync(path.join(dir, 'Contents.json'), `${JSON.stringify({
		images: [{ filename, idiom: 'universal' }],
		info: { author: 'xcode', version: 1 },
		properties: {
			'preserves-vector-representation': true,
			'template-rendering-intent': template ? 'template' : 'original',
		},
	}, null, 2)}\n`)
}

for (const [name, iconPath] of Object.entries(DUOTONE_CATALOG)) {
	const svg = svgFor(extractElements(iconPath), { template: true })
	writeImageset(name, svg, true)
	console.log(`duotone ${name}`)
}

// Outline assets render at stroke-width 2 (Solar ships 1.5) — see SolarIcons.swift.
for (const [name, iconPath] of Object.entries(OUTLINE_ICONS)) {
	const svg = svgFor(extractElements(iconPath), { template: true, strokeWidth: '2' })
	writeImageset(name, svg, true)
	console.log(`outline ${name}`)
}

for (const [name, paths] of Object.entries(STROKE_ICONS)) {
	writeImageset(name, strokeSvgFor(paths), true)
	console.log(`stroke ${name}`)
}

for (const [name, body] of Object.entries(HAND_TUNED_ICONS)) {
	writeImageset(name, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${body}</svg>`, true)
	console.log(`hand-tuned ${name}`)
}
