import { useEffect, useRef } from 'react'

// Ordered 4x4 Bayer threshold matrix echoing SwiftDitherKit's halftone rendering
// inside the iOS app.
const BAYER_4X4 = [
	[0, 8, 2, 10],
	[12, 4, 14, 6],
	[3, 11, 1, 9],
	[15, 7, 13, 5],
] as const

/**
 * Crisp 4x4 Bayer ordered-dither sunrise field behind the hero iPhone.
 * Renders warm Cloudflare ember halftones that dissolve pixel-by-pixel into
 * the stone gallery canvas, echoing Dash's own `SwiftDitherKit` charts and
 * `DashWorkspaceTopWash`. Static when `prefers-reduced-motion` is set.
 */
export function DitheredSunriseCanvas({ className }: { className?: string }) {
	const canvasRef = useRef<HTMLCanvasElement>(null)

	useEffect(() => {
		const canvas = canvasRef.current
		if (!canvas) {
			return
		}
		const ctx = canvas.getContext('2d')
		if (!ctx) {
			return
		}

		const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
		let width = 0
		let height = 0
		let dpr = 1
		let rafId = 0

		const resize = () => {
			const rect = canvas.getBoundingClientRect()
			dpr = Math.min(window.devicePixelRatio || 1, 2)
			width = Math.max(1, Math.round(rect.width))
			height = Math.max(1, Math.round(rect.height))
			canvas.width = Math.round(width * dpr)
			canvas.height = Math.round(height * dpr)
		}

		const draw = (timeMs: number) => {
			ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
			ctx.clearRect(0, 0, width, height)

			// Soft ambient sunrise wash underneath the ordered halftone dots so
			// the field reads warm and luminous rather than sparse.
			const ambient = ctx.createRadialGradient(
				width * 0.5,
				height * -0.06,
				0,
				width * 0.5,
				height * 0.08,
				Math.max(width * 0.62, height * 0.78),
			)
			ambient.addColorStop(0, 'rgba(246, 130, 31, 0.22)')
			ambient.addColorStop(0.42, 'rgba(248, 165, 96, 0.11)')
			ambient.addColorStop(0.78, 'rgba(244, 242, 238, 0)')
			ctx.fillStyle = ambient
			ctx.fillRect(0, 0, width, height)

			// Ordered Bayer halftone layer: crisp 2.6px cells on a 5px grid.
			const step = 5
			const dot = 2.6
			const cols = Math.ceil(width / step)
			const rows = Math.ceil(height / step)
			const drift = reducedMotion ? 0 : Math.sin(timeMs * 0.00045) * 0.028

			for (let row = 0; row < rows; row++) {
				const py = row * step
				const ny = py / height
				if (ny > 0.88) {
					break
				}
				const bayerRow = BAYER_4X4[row & 3]

				for (let col = 0; col < cols; col++) {
					const px = col * step
					const nx = px / width

					const dx = (nx - 0.5) / 0.44
					const dy = (ny + 0.06) / 0.72
					const distSq = dx * dx + dy * dy
					if (distSq >= 1.1) {
						continue
					}

					const falloff = Math.max(0, 1 - distSq)
					const intensity = falloff * falloff * 0.78 + drift * falloff
					const threshold = (bayerRow[col & 3] + 0.5) / 16

					if (intensity > threshold) {
						const alpha = Math.min(0.42, 0.11 + falloff * 0.29)
						ctx.fillStyle = `rgba(235, 114, 24, ${alpha.toFixed(3)})`
						ctx.fillRect(px, py, dot, dot)
					}
				}
			}
		}

		resize()
		draw(0)

		const ro = new ResizeObserver(() => {
			resize()
			draw(performance.now())
		})
		ro.observe(canvas)

		if (!reducedMotion) {
			let lastFrame = 0
			const tick = (now: number) => {
				if (now - lastFrame >= 66) {
					lastFrame = now
					draw(now)
				}
				rafId = window.requestAnimationFrame(tick)
			}
			rafId = window.requestAnimationFrame(tick)
		}

		return () => {
			ro.disconnect()
			if (rafId) {
				window.cancelAnimationFrame(rafId)
			}
		}
	}, [])

	return (
		<canvas
			aria-hidden="true"
			className={className}
			ref={canvasRef}
		/>
	)
}

/**
 * Monumental Bayer-halftone "Dash" wordmark for the footer monolith.
 * Covers the entire stone footer container so the bottom sunrise glow fades
 * seamlessly without a seam, while the giant "Dash" letterforms anchor to the
 * bottom edge and dissolve downward through the 4x4 ordered Bayer matrix.
 */
export function DitheredWordmarkCanvas({ className }: { className?: string }) {
	const canvasRef = useRef<HTMLCanvasElement>(null)

	useEffect(() => {
		const canvas = canvasRef.current
		if (!canvas) {
			return
		}
		const ctx = canvas.getContext('2d')
		if (!ctx) {
			return
		}

		let cancelled = false

		const draw = () => {
			if (cancelled) {
				return
			}
			const rect = canvas.getBoundingClientRect()
			const width = Math.max(1, Math.round(rect.width))
			const height = Math.max(1, Math.round(rect.height))
			const dpr = Math.min(window.devicePixelRatio || 1, 2)

			canvas.width = Math.round(width * dpr)
			canvas.height = Math.round(height * dpr)

			ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
			ctx.clearRect(0, 0, width, height)

			// Mirror of the hero's top sunrise wash, rising cleanly from the bottom
			// edge and fading out smoothly before reaching the footer links above.
			const glowRadius = Math.min(width * 0.62, height * 0.92)
			const ambient = ctx.createRadialGradient(
				width * 0.5,
				height * 1.06,
				0,
				width * 0.5,
				height * 0.98,
				glowRadius,
			)
			ambient.addColorStop(0, 'rgba(246, 130, 31, 0.2)')
			ambient.addColorStop(0.45, 'rgba(248, 168, 102, 0.09)')
			ambient.addColorStop(1, 'rgba(244, 242, 238, 0)')
			ctx.fillStyle = ambient
			ctx.fillRect(0, 0, width, height)

			// Rasterize "Dash" onto an offscreen 1x mask spanning ~88% of the card
			// width, anchored to the bottom horizon.
			const mask = document.createElement('canvas')
			mask.width = width
			mask.height = height
			const mctx = mask.getContext('2d', { willReadFrequently: true })
			if (!mctx) {
				return
			}

			const word = 'Dash'
			const letters = [...word]
			const probeSize = 200
			const fontFamily = '\'Inter\', -apple-system, BlinkMacSystemFont, \'SF Pro Display\', system-ui, sans-serif'
			mctx.font = `600 ${probeSize}px ${fontFamily}`

			const trackingRatio = -0.055
			const probeWidths = letters.map(ch => mctx.measureText(ch).width)
			const probeTotal = probeWidths.reduce((sum, w) => sum + w, 0)
				+ (letters.length - 1) * probeSize * trackingRatio

			const maxByWidth = ((width * 0.88) / Math.max(1, probeTotal)) * probeSize
			const maxByHeight = height * 0.72
			const fontSize = Math.max(72, Math.min(maxByWidth, maxByHeight))

			mctx.font = `600 ${fontSize}px ${fontFamily}`
			mctx.textBaseline = 'alphabetic'
			mctx.fillStyle = '#000'

			const tracking = fontSize * trackingRatio
			const widths = letters.map(ch => mctx.measureText(ch).width)
			const totalWidth = widths.reduce((sum, w) => sum + w, 0) + (letters.length - 1) * tracking
			let cursorX = (width - totalWidth) * 0.5
			const baselineY = height + fontSize * 0.04
			const glyphTop = Math.max(0, baselineY - fontSize * 0.74)
			const glyphSpan = Math.max(1, height - glyphTop)

			for (let i = 0; i < letters.length; i++) {
				mctx.fillText(letters[i], cursorX, baselineY)
				cursorX += widths[i] + tracking
			}

			const { data } = mctx.getImageData(0, 0, width, height)
			const step = width < 520 ? 3 : 4
			const dot = width < 520 ? 2 : 2.6
			const cols = Math.ceil(width / step)
			const rows = Math.ceil(height / step)
			const startRow = Math.max(0, Math.floor((glyphTop - height * 0.14) / step))

			for (let row = startRow; row < rows; row++) {
				const py = row * step
				const ny = py / height
				const bayerRow = BAYER_4X4[row & 3]
				const sampleY = Math.min(height - 1, py + 1)

				for (let col = 0; col < cols; col++) {
					const px = col * step
					const nx = px / width
					const sampleX = Math.min(width - 1, px + 1)
					const glyphAlpha = data[(sampleY * width + sampleX) * 4 + 3] / 255
					const threshold = (bayerRow[col & 3] + 0.5) / 16

					if (glyphAlpha > 0.28) {
						const t = Math.max(0, Math.min(1, (py - glyphTop) / glyphSpan))
						// Crisp dense halftone across the crown, opening up into sunlit
						// ember dots as the letters meet the horizon.
						const density = 0.96 - t * 0.62
						if (density > threshold) {
							const warm = t ** 1.35
							const r = Math.round(24 + (235 - 24) * warm)
							const g = Math.round(23 + (114 - 23) * warm)
							const b = Math.round(21 + (24 - 21) * warm)
							const a = 0.24 + warm * 0.2
							ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${a.toFixed(3)})`
							ctx.fillRect(px, py, dot, dot)
						}
					}
					else if (py >= glyphTop - height * 0.08) {
						// Quiet ambient horizon halftone mirroring the hero sunrise.
						const dx = (nx - 0.5) / 0.52
						const dy = (1.06 - ny) / 0.44
						const distSq = dx * dx + dy * dy
						if (distSq < 1) {
							const falloff = 1 - distSq
							const ambientIntensity = falloff * falloff * 0.42
							if (ambientIntensity > threshold) {
								const alpha = 0.09 + falloff * 0.17
								ctx.fillStyle = `rgba(235, 114, 24, ${alpha.toFixed(3)})`
								ctx.fillRect(px, py, dot, dot)
							}
						}
					}
				}
			}
		}

		draw()

		if (document.fonts?.ready) {
			void document.fonts.ready.then(draw)
		}

		const ro = new ResizeObserver(draw)
		ro.observe(canvas)

		return () => {
			cancelled = true
			ro.disconnect()
		}
	}, [])

	return (
		<canvas
			aria-hidden="true"
			className={className}
			ref={canvasRef}
		/>
	)
}
