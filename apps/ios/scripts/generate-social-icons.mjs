#!/usr/bin/env node
/**
 * Generates MingCute social/logo SVG assets for Dash iOS (About → Developer).
 *
 * Sources the classic line glyphs (`social_x_line`, `github_line`) from the
 * `mingcute_icon` package, strips the icon-font spacer path, and writes
 * template fill assets so they tint with Settings' `iconMuted`.
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
const mingcuteRoot = path.dirname(require.resolve('mingcute_icon/package.json'))

/**
 * Asset name → MingCute SVG under `svg/logo/`.
 * Line marks match Settings' outline chrome weight better than the filled set.
 */
const SOCIAL_ICONS = {
	MingCuteGithubLine: 'github_line.svg',
	MingCuteSocialXLine: 'social_x_line.svg',
}

/**
 * MingCute logo SVGs wrap a transparent 24×24 spacer path (icon-font advance)
 * plus the drawable mark. Keep only the filled mark, recolored for template
 * rendering. Preserve `evenodd` when the source group uses it — `social_x_line`
 * punches its cross-bar counter that way.
 * @param {string} svg
 */
function templateSvgFor(svg) {
	const paths = [...svg.matchAll(/<path\b[^>]*>/g)].map(match => match[0])
	const drawable = paths.find(pathTag =>
		/\bfill="(?!none)[^"]+"/i.test(pathTag) && !/\bd="M24 0v24H0V0/i.test(pathTag)
	)
	if (!drawable)
		throw new Error('no drawable filled path found')

	const evenodd = /fill-rule="evenodd"/i.test(svg)
	let body = drawable
		.replace(/\bfill="[^"]+"/i, 'fill="#000"')
		.replace(/\s*\/>?$/, '/>')
	if (evenodd && !/fill-rule=/i.test(body))
		body = body.replace('<path ', '<path fill-rule="evenodd" ')
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${body}</svg>`
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

function generateSocialIcons() {
	for (const [name, file] of Object.entries(SOCIAL_ICONS)) {
		const sourcePath = path.join(mingcuteRoot, 'svg/logo', file)
		const source = fs.readFileSync(sourcePath, 'utf8')
		writeImageset(name, templateSvgFor(source))
		console.log(`social ${name}`)
	}
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
	generateSocialIcons()

export { generateSocialIcons, templateSvgFor }
