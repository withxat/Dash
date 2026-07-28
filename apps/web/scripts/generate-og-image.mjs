#!/usr/bin/env node
// Builds the Open Graph / Twitter card image from the real device capture, so
// the shared link shows the product rather than a bare text preview.
//
//   node apps/web/scripts/generate-og-image.mjs
//
// Output: apps/web/public/og.png (1200x630, the size both Open Graph and
// Twitter summary_large_image expect).

import { Buffer } from 'node:buffer'
import { stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import sharp from 'sharp'

const here = path.dirname(fileURLToPath(import.meta.url))
const webRoot = path.resolve(here, '..')

const WIDTH = 1200
const HEIGHT = 630

// Kumo light surfaces, matched to the landing page.
const CANVAS = '#fbfbfb'
const STRONG = '#252525'
const SUBTLE = '#6b6b6b'

const CAPTURE = path.join(webRoot, 'public/screens/zone.webp')
const ICON = path.resolve(
	webRoot,
	'../ios/Dash/Resources/Assets.xcassets/LoginAppIcon.imageset/LoginAppIcon.png',
)
const OUT = path.join(webRoot, 'public/og.png')

// The capture is a full 19.5:9 portrait screen. Show its top two thirds so the
// zone card and the first quick actions read at card size, then round the
// corners the same way the site frames it.
const SHOT_W = 380
const SHOT_H = 560
const SHOT_X = 760
const SHOT_Y = 96
const RADIUS = 34

async function roundedCapture() {
	const resized = await sharp(CAPTURE)
		.resize({ height: Math.round((SHOT_W * 2622) / 1206), position: 'top', width: SHOT_W })
		.toBuffer()

	const cropped = await sharp(resized)
		.extract({ height: SHOT_H, left: 0, top: 0, width: SHOT_W })
		.toBuffer()

	const mask = Buffer.from(
		`<svg width="${SHOT_W}" height="${SHOT_H}"><rect width="${SHOT_W}" height="${SHOT_H}" rx="${RADIUS}" ry="${RADIUS}" fill="#fff"/></svg>`,
	)

	return sharp(cropped)
		.composite([{ blend: 'dest-in', input: mask }])
		.png()
		.toBuffer()
}

const text = Buffer.from(`
<svg width="${WIDTH}" height="${HEIGHT}" xmlns="http://www.w3.org/2000/svg">
	<style>
		.wordmark { font: 600 34px -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; fill: ${STRONG}; }
		.headline { font: 600 72px -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; fill: ${STRONG}; letter-spacing: -2.6px; }
		.sub { font: 400 26px -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; fill: ${SUBTLE}; }
	</style>
	<text class="wordmark" x="162" y="122">Dash</text>
	<text class="headline" x="96" y="272">Run Cloudflare</text>
	<text class="headline" x="96" y="352">beyond the desk.</text>
	<text class="sub" x="96" y="432">A native iPhone client for your Cloudflare account.</text>
	<text class="sub" x="96" y="474">Zones, Workers, Pages, R2, and KV.</text>
</svg>
`)

// The source icon art is a square; round it to the iOS squircle radius so the
// lockup matches the app icon everywhere else on the site.
const ICON_SIZE = 56
const iconMask = Buffer.from(
	`<svg width="${ICON_SIZE}" height="${ICON_SIZE}"><rect width="${ICON_SIZE}" height="${ICON_SIZE}" rx="13" ry="13" fill="#fff"/></svg>`,
)
const icon = await sharp(ICON)
	.resize(ICON_SIZE, ICON_SIZE)
	.composite([{ blend: 'dest-in', input: iconMask }])
	.png()
	.toBuffer()

await sharp({
	create: {
		background: CANVAS,
		channels: 4,
		height: HEIGHT,
		width: WIDTH,
	},
})
	.composite([
		{ input: await roundedCapture(), left: SHOT_X, top: SHOT_Y },
		{ input: icon, left: 96, top: 76 },
		{ input: text, left: 0, top: 0 },
	])
	.png()
	.toFile(OUT)

const { size } = await stat(OUT)
console.log(`generate-og-image: wrote ${path.relative(webRoot, OUT)} (${Math.round(size / 1024)}KB)`)
