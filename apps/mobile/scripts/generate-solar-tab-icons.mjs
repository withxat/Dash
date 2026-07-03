#!/usr/bin/env node
import { Buffer } from 'node:buffer'
/**
 * Generates template PNG tab icons from Solar icon paths
 * (@solar-icons/react-native — Linear for default, Bold for selected).
 * Run: node scripts/generate-solar-tab-icons.mjs
 *
 * Exports @1x/@2x/@3x so React Native maps them to ~25pt tab bar icons
 * (a single 75px file named *.png is treated as @1x → 75pt on device).
 */
import fs from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import sharp from 'sharp'

const require = createRequire(import.meta.url)
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const outDir = path.join(__dirname, '../assets/tab-icons')

const solarRoot = path.dirname(require.resolve('@solar-icons/react-native/package.json'))

/** Solar icons per tab: Linear (line) for default, Bold (fill) for selected. */
const ICONS = {
	'home-fill': 'ui/Bold/Home2',
	'home-line': 'ui/Linear/Home2',
	'items-fill': 'settings/Bold/Widget',
	'items-line': 'settings/Linear/Widget',
	'search-fill': 'search/Bold/Magnifier',
	'search-line': 'search/Linear/Magnifier',
	'watchtower-fill': 'business/Bold/Chart',
	'watchtower-line': 'business/Linear/Chart',
}

/** iOS tab bar slot is 25×25 pt. */
const BASE_PT = 25
const VIEWBOX = 24

const SCALES = [
	{ scale: 1, suffix: '' },
	{ scale: 2, suffix: '@2x' },
	{ scale: 3, suffix: '@3x' },
]

/** Extracts Path/Circle props (d/cx/cy/r, stroke vs fill, fill/clip rules) from a compiled icon module. */
function extractElements(iconPath) {
	const source = fs.readFileSync(path.join(solarRoot, 'dist/icons', `${iconPath}.mjs`), 'utf8')
	const elements = []
	for (const match of source.matchAll(/\{([^{}]*?(?:d|cx):`[^`]+`[^{}]*)\}/g)) {
		const attrs = match[1]
		const common = {
			stroke: attrs.includes('stroke:'),
			strokeWidth: attrs.match(/strokeWidth:`([^`]+)`/)?.[1] ?? '1.5',
		}
		const d = attrs.match(/d:`([^`]+)`/)?.[1]
		if (d) {
			elements.push({
				...common,
				clipRule: attrs.match(/clipRule:`([^`]+)`/)?.[1],
				d,
				fillRule: attrs.match(/fillRule:`([^`]+)`/)?.[1],
				tag: 'path',
			})
			continue
		}
		const cx = attrs.match(/cx:`([^`]+)`/)?.[1]
		const cy = attrs.match(/cy:`([^`]+)`/)?.[1]
		const r = attrs.match(/r:`([^`]+)`/)?.[1]
		if (cx && cy && r)
			elements.push({ ...common, cx, cy, r, tag: 'circle' })
	}
	if (elements.length === 0)
		throw new Error(`${iconPath}: no drawable elements found`)
	return elements
}

function svgFor(elements, outputPx) {
	const body = elements.map((el) => {
		const paint = el.stroke
			? `fill="none" stroke="#000" stroke-width="${el.strokeWidth}" stroke-linecap="round" stroke-linejoin="round"`
			: 'fill="#000"'
		if (el.tag === 'circle')
			return `<circle cx="${el.cx}" cy="${el.cy}" r="${el.r}" ${paint}/>`
		const fillRule = el.fillRule ? ` fill-rule="${el.fillRule}"` : ''
		const clipRule = el.clipRule ? ` clip-rule="${el.clipRule}"` : ''
		return `<path d="${el.d}" ${paint}${fillRule}${clipRule}/>`
	}).join('')
	return `<svg xmlns="http://www.w3.org/2000/svg" width="${outputPx}" height="${outputPx}" viewBox="0 0 ${VIEWBOX} ${VIEWBOX}">${body}</svg>`
}

fs.mkdirSync(outDir, { recursive: true })

for (const [name, iconPath] of Object.entries(ICONS)) {
	const elements = extractElements(iconPath)
	for (const { scale, suffix } of SCALES) {
		const outputPx = BASE_PT * scale
		const file = path.join(outDir, `${name}${suffix}.png`)
		await sharp(Buffer.from(svgFor(elements, outputPx))).png().toFile(file)
		console.log(`wrote ${path.basename(file)} (${outputPx}px)`)
	}
}
