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

/** @typedef {{ tag: 'path' | 'circle' | 'ellipse' | 'rect' | 'g', d?: string, cx?: string, cy?: string, r?: string, rx?: string, ry?: string, x?: string, y?: string, width?: string, height?: string, stroke?: boolean, strokeWidth?: string, strokeLinecap?: string, strokeLinejoin?: string, fillRule?: string, clipRule?: string, opacity?: string, children?: Element[] }} Element */

/** Catalog Bold Duotone icons (Items layer). */
const DUOTONE_CATALOG = {
	SolarGlobal: 'map/BoldDuotone/Global',
	SolarGlobus: 'map/BoldDuotone/Globus',
	SolarCodeSquare: 'it/BoldDuotone/CodeSquare',
	SolarCloudStorage: 'devices/BoldDuotone/CloudStorage',
	SolarKeyMinimalistic: 'security/BoldDuotone/KeyMinimalistic',
	SolarDatabase: 'ui/BoldDuotone/Database',
	SolarInbox: 'messages/BoldDuotone/Inbox',
	SolarShieldUser: 'security/BoldDuotone/ShieldUser',
	SolarUsersGroupRounded: 'users/BoldDuotone/UsersGroupRounded',
	SolarShieldStar: 'security/BoldDuotone/ShieldStar',
	SolarKey: 'security/BoldDuotone/Key',
	SolarRouting: 'map/BoldDuotone/Routing',
	SolarLockPassword: 'security/BoldDuotone/LockPassword',
	SolarBoltCircle: 'ui/BoldDuotone/BoltCircle',
	SolarChart2: 'business/BoldDuotone/Chart2',
	SolarUserCircle: 'users/BoldDuotone/UserCircle',
}

/** Catalog + UI Linear outline icons (sub-pages). */
const OUTLINE_ICONS = {
	SolarGlobalOutline: 'map/Linear/Global',
	SolarGlobusOutline: 'map/Linear/Globus',
	SolarCodeSquareOutline: 'it/Linear/CodeSquare',
	SolarBoxOutline: 'ui/Linear/Box',
	SolarHeartPulseOutline: 'medicine/Linear/HeartPulse',
	SolarCloudStorageOutline: 'devices/Linear/CloudStorage',
	SolarKeyMinimalisticOutline: 'security/Linear/KeyMinimalistic',
	SolarDatabaseOutline: 'ui/Linear/Database',
	SolarInboxOutline: 'messages/Linear/Inbox',
	SolarBoltOutline: 'ui/Linear/Bolt',
	SolarLockKeyholeOutline: 'security/Linear/LockKeyhole',
	SolarShieldCheckOutline: 'security/Linear/ShieldCheck',
	SolarShieldUserOutline: 'security/Linear/ShieldUser',
	SolarUsersGroupRoundedOutline: 'users/Linear/UsersGroupRounded',
	SolarShieldStarOutline: 'security/Linear/ShieldStar',
	SolarKeyOutline: 'security/Linear/Key',
	SolarShieldOutline: 'security/Linear/Shield',
	SolarRoutingOutline: 'map/Linear/Routing',
	SolarLockPasswordOutline: 'security/Linear/LockPassword',
	SolarBoltCircleOutline: 'ui/Linear/BoltCircle',
	SolarGalleryOutline: 'video/Linear/Gallery',
	SolarVideoLibraryOutline: 'video/Linear/VideoLibrary',
	SolarChart2Outline: 'business/Linear/Chart2',
	SolarUserCircleOutline: 'users/Linear/UserCircle',
	SolarBoxMinimalisticOutline: 'ui/Linear/BoxMinimalistic',
	SolarSettingsMinimalisticOutline: 'settings/Linear/SettingsMinimalistic',
	SolarAltArrowRightOutline: 'arrows/Linear/AltArrowRight',
	SolarAltArrowLeftOutline: 'arrows/Linear/AltArrowLeft',
	SolarDangerTriangleOutline: 'ui/Linear/DangerTriangle',
	SolarCodeCircleOutline: 'it/Linear/CodeCircle',
	SolarPenNewSquareOutline: 'messages/Linear/PenNewSquare',
	SolarTrashBinOutline: 'ui/Linear/TrashBinMinimalistic',
	SolarCloudOutline: 'weather/Linear/Cloud',
	SolarFileOutline: 'files/Linear/File',
	SolarUploadOutline: 'arrows-action/Linear/Upload',
	SolarMagnifierOutline: 'search/Linear/MinimalisticMagnifier',
	SolarCheckCircleOutline: 'ui/Linear/CheckCircle',
	SolarClockCircleOutline: 'time/Linear/ClockCircle',
	SolarSliderHorizontalOutline: 'ui/Linear/SliderMinimalisticHorizontal',
	SolarPinListOutline: 'ui/Linear/PinList',
	SolarPinOutline: 'ui/Linear/Pin',
	SolarPinBold: 'ui/Bold/Pin',
	SolarCheckCircleBold: 'ui/Bold/CheckCircle',
	SolarUsersGroupOutline: 'users/Linear/UsersGroupRounded',
}

const OUTLINE_STROKE_WIDTHS = {
	SolarAltArrowRightOutline: '2.5',
	SolarAltArrowLeftOutline: '2.5',
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

const FLAT_DRAWABLE_TAGS = new Set(['Path', 'Circle', 'Ellipse', 'Rect'])

function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function importAliases(source, moduleName) {
	const match = source.match(
		new RegExp(`import\\s*\\{([^}]*)\\}\\s*from\\s*"${escapeRegExp(moduleName)}"`),
	)
	if (!match)
		throw new Error(`Missing named import from ${moduleName}`)

	return new Map(match[1].split(',').map((entry) => {
		const [importedName, localName = importedName] = entry.trim().split(/\s+as\s+/)
		return [localName, importedName]
	}))
}

function templateAttribute(attributes, name) {
	return attributes.match(new RegExp(`${escapeRegExp(name)}:\`([^\`]*)\``))?.[1]
}

/** @returns {Element} */
function elementFromAttributes(tagName, attributes) {
	const base = {
		stroke: templateAttribute(attributes, 'stroke') !== undefined,
		strokeWidth: templateAttribute(attributes, 'strokeWidth') ?? '1.5',
		strokeLinecap: templateAttribute(attributes, 'strokeLinecap'),
		strokeLinejoin: templateAttribute(attributes, 'strokeLinejoin'),
		fillRule: templateAttribute(attributes, 'fillRule'),
		clipRule: templateAttribute(attributes, 'clipRule'),
		opacity: templateAttribute(attributes, 'opacity'),
	}

	switch (tagName) {
		case 'Path': {
			const d = templateAttribute(attributes, 'd')
			if (!d)
				throw new Error('Path is missing d')
			return { tag: 'path', d, ...base }
		}
		case 'Circle': {
			const cx = templateAttribute(attributes, 'cx')
			const cy = templateAttribute(attributes, 'cy')
			const r = templateAttribute(attributes, 'r')
			if (!(cx && cy && r))
				throw new Error('Circle is missing cx, cy, or r')
			return { tag: 'circle', cx, cy, r, ...base }
		}
		case 'Ellipse': {
			const cx = templateAttribute(attributes, 'cx')
			const cy = templateAttribute(attributes, 'cy')
			const rx = templateAttribute(attributes, 'rx')
			const ry = templateAttribute(attributes, 'ry')
			if (!(cx && cy && rx && ry))
				throw new Error('Ellipse is missing cx, cy, rx, or ry')
			return { tag: 'ellipse', cx, cy, rx, ry, ...base }
		}
		case 'Rect': {
			const x = templateAttribute(attributes, 'x')
			const y = templateAttribute(attributes, 'y')
			const width = templateAttribute(attributes, 'width')
			const height = templateAttribute(attributes, 'height')
			if (!(x && y && width && height))
				throw new Error('Rect is missing x, y, width, or height')
			return {
				tag: 'rect',
				x,
				y,
				width,
				height,
				rx: templateAttribute(attributes, 'rx'),
				ry: templateAttribute(attributes, 'ry'),
				...base,
			}
		}
		default:
			throw new Error(`Unsupported flat SVG tag: ${tagName}`)
	}
}

/** @returns {Element[]} */
function extractFlatElements(source, svgAliases, jsxAliases) {
	const drawableAliases = [...svgAliases]
		.filter(([, tagName]) => FLAT_DRAWABLE_TAGS.has(tagName))
		.map(([alias]) => escapeRegExp(alias))
	const pattern = new RegExp(
		`(?:${jsxAliases.map(escapeRegExp).join('|')})\\((${drawableAliases.join('|')}),\\{([^}]*)\\}\\)`,
		'g',
	)

	return [...source.matchAll(pattern)].map((match) =>
		elementFromAttributes(svgAliases.get(match[1]), match[2]))
}

/** Preserves the existing flattening behavior for Solar assets that contain groups. */
function extractGroupedElements(source) {
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

	return elements
}

function sourceDrawableCount(source, svgAliases, jsxAliases) {
	const jsxPattern = jsxAliases.map(escapeRegExp).join('|')
	let count = 0

	for (const [alias, tagName] of svgAliases) {
		if (!FLAT_DRAWABLE_TAGS.has(tagName))
			continue
		count += [...source.matchAll(
			new RegExp(`(?:${jsxPattern})\\(${escapeRegExp(alias)},\\{`, 'g'),
		)].length
	}

	return count
}

function extractedDrawableCount(elements) {
	return elements.reduce(
		(count, element) =>
			count + (element.tag === 'g' ? extractedDrawableCount(element.children ?? []) : 1),
		0,
	)
}

/** @returns {Element[]} */
function extractElements(iconPath) {
	const source = fs.readFileSync(path.join(solarRoot, 'dist/icons', `${iconPath}.mjs`), 'utf8')
	const svgAliases = importAliases(source, 'react-native-svg')
	const jsxAliases = [...importAliases(source, 'react/jsx-runtime')]
		.filter(([, importedName]) => importedName === 'jsx' || importedName === 'jsxs')
		.map(([alias]) => alias)
	const hasGroup = [...svgAliases.values()].includes('G')
	const elements = hasGroup
		? extractGroupedElements(source)
		: extractFlatElements(source, svgAliases, jsxAliases)
	const expectedCount = sourceDrawableCount(source, svgAliases, jsxAliases)
	const actualCount = extractedDrawableCount(elements)

	if (elements.length === 0)
		throw new Error(`${iconPath}: no drawable elements found`)
	if (actualCount !== expectedCount) {
		throw new Error(
			`${iconPath}: extracted ${actualCount} of ${expectedCount} drawable elements`,
		)
	}
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

	if (el.tag === 'circle' || el.tag === 'ellipse' || el.tag === 'rect') {
		const geometry =
			el.tag === 'circle'
				? `cx="${el.cx}" cy="${el.cy}" r="${el.r}"`
				: el.tag === 'ellipse'
					? `cx="${el.cx}" cy="${el.cy}" rx="${el.rx}" ry="${el.ry}"`
					: `x="${el.x}" y="${el.y}" width="${el.width}" height="${el.height}"${
						el.rx ? ` rx="${el.rx}"` : ''
					}${el.ry ? ` ry="${el.ry}"` : ''}`
		const paint = el.stroke
			? `fill="none" stroke="#000" stroke-width="${strokeWidth ?? el.strokeWidth}"`
			: `fill="#000"`
		const opacity = el.opacity ? ` opacity="${el.opacity}"` : ''
		return `<${el.tag} ${geometry} ${paint}${opacity}/>`
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

function generateAllIcons() {
	for (const [name, iconPath] of Object.entries(DUOTONE_CATALOG)) {
		const svg = svgFor(extractElements(iconPath), { template: true })
		writeImageset(name, svg, true)
		console.log(`duotone ${name}`)
	}

	// Outline assets render at stroke-width 2 (Solar ships 1.5) — see SolarIcons.swift.
	for (const [name, iconPath] of Object.entries(OUTLINE_ICONS)) {
		const svg = svgFor(extractElements(iconPath), {
			template: true,
			strokeWidth: OUTLINE_STROKE_WIDTHS[name] ?? '2',
		})
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
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
	generateAllIcons()

export { extractElements, generateAllIcons, svgFor }
