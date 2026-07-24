#!/usr/bin/env node
/**
 * Generates Hugeicons "02" file-format SVG assets for Dash iOS R2 rows.
 *
 * These are the document-with-folded-corner glyphs (Pdf, Doc, Zip, …) shown as
 * the leading icon for non-image objects in the R2 browser. Rendered as
 * template stroke assets so they tint with the row's icon color, matching the
 * Solar chrome pipeline in generate-solar-icons.mjs.
 *
 * Run: pnpm ios:icons (runs alongside the Solar generator)
 */
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'

const require = createRequire(import.meta.url)
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const assetsDir = path.join(__dirname, '../Dash/Resources/Assets.xcassets')
const hugeRoot = path.dirname(require.resolve('@hugeicons/core-free-icons/package.json'))

/**
 * Asset name → Hugeicons export base name (the `…Icon.js` module under
 * dist/esm). Every glyph is from the "02" file-format family so the row icons
 * read as one set; formats Hugeicons doesn't ship fall back to `HugeFile02`
 * in FileTypeIcons.swift.
 */
const FILE_ICONS = {
	HugeFile02: 'File02',
	HugePdf02: 'Pdf02',
	HugeDoc02: 'Doc02',
	HugeTxt02: 'Txt02',
	HugeCsv02: 'Csv02',
	HugeXls02: 'Xls02',
	HugePpt02: 'Ppt02',
	HugeZip02: 'Zip02',
	HugeRar02: 'Rar02',
	HugeSvg02: 'Svg02',
	HugePng02: 'Png02',
	HugeJpg02: 'Jpg02',
	HugeGif02: 'Gif02',
	HugeFileImage: 'FileImage',
	HugeFilePlay: 'FilePlay',
	HugeWav02: 'Wav02',
	HugeXml02: 'Xml02',
	HugeHtml02: 'HtmlFile02',
	HugeCss02: 'CssFile02',
	HugeJsx03: 'Jsx03',
}

/** Hugeicons ships stroke glyphs at 1.5 on a 24×24 grid — keep it authentic. */
const STROKE_WIDTH = '1.5'

/**
 * Each Hugeicons module default-exports an `IconSvgObject`: an array of
 * `[tagName, attributes]` tuples where `stroke` is the sentinel "currentColor".
 * @returns {Promise<[string, Record<string, string>][]>}
 */
async function loadIcon(baseName) {
	const modulePath = path.join(hugeRoot, 'dist/esm', `${baseName}Icon.js`)
	const module = await import(pathToFileURL(modulePath).href)
	const elements = module.default
	if (!Array.isArray(elements) || elements.length === 0)
		throw new Error(`${baseName}: no drawable elements found`)
	return elements
}

/** @param {[string, Record<string, string>][]} elements */
function svgFor(elements) {
	const body = elements.map(([tag, attrs]) => renderElement(tag, attrs)).join('')
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${body}</svg>`
}

/** @param {string} tag @param {Record<string, string>} attrs */
function renderElement(tag, attrs) {
	// currentColor → #000; template rendering re-tints at display time.
	const stroked = attrs.stroke !== undefined && attrs.stroke !== 'none'
	const cap = attrs.strokeLinecap ?? 'round'
	const join = attrs.strokeLinejoin ?? 'round'
	const paint = stroked
		? `fill="none" stroke="#000" stroke-width="${STROKE_WIDTH}" stroke-linecap="${cap}" stroke-linejoin="${join}"`
		: 'fill="#000"'

	switch (tag) {
		case 'path':
			if (!attrs.d)
				throw new Error('path is missing d')
			return `<path d="${attrs.d}" ${paint}/>`
		case 'circle':
			return `<circle cx="${attrs.cx}" cy="${attrs.cy}" r="${attrs.r}" ${paint}/>`
		case 'ellipse':
			return `<ellipse cx="${attrs.cx}" cy="${attrs.cy}" rx="${attrs.rx}" ry="${attrs.ry}" ${paint}/>`
		case 'rect':
			return `<rect x="${attrs.x}" y="${attrs.y}" width="${attrs.width}" height="${attrs.height}"${
				attrs.rx ? ` rx="${attrs.rx}"` : ''
			}${attrs.ry ? ` ry="${attrs.ry}"` : ''} ${paint}/>`
		case 'line':
			return `<line x1="${attrs.x1}" y1="${attrs.y1}" x2="${attrs.x2}" y2="${attrs.y2}" ${paint}/>`
		default:
			throw new Error(`Unsupported Hugeicons tag: ${tag}`)
	}
}

function writeImageset(name, svg) {
	const dir = path.join(assetsDir, `${name}.imageset`)
	fs.mkdirSync(dir, { recursive: true })
	const filename = `${name}.svg`
	fs.writeFileSync(path.join(dir, filename), svg)
	fs.writeFileSync(path.join(dir, 'Contents.json'), `${JSON.stringify({
		images: [{ filename, idiom: 'universal' }],
		info: { author: 'xcode', version: 1 },
		properties: {
			'preserves-vector-representation': true,
			'template-rendering-intent': 'template',
		},
	}, null, 2)}\n`)
}

async function generateFileIcons() {
	for (const [name, baseName] of Object.entries(FILE_ICONS)) {
		const svg = svgFor(await loadIcon(baseName))
		writeImageset(name, svg)
		console.log(`file ${name}`)
	}
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
	await generateFileIcons()

export { generateFileIcons, svgFor }
