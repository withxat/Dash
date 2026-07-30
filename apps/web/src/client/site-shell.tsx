import type { ReactNode } from 'react'

import { LinkButton } from '@cloudflare/kumo/components/button'
import { Link } from '@cloudflare/kumo/components/link'
import { GithubLogoIcon } from '@phosphor-icons/react/dist/ssr/GithubLogo'
import { AnimatePresence, motion, useReducedMotion } from 'motion/react'
import { useEffect, useState } from 'react'

import { dashAppIconUrl } from './brand-assets'

// Same curve and duration as motion-primitives — one site, one entrance feel.
const EASE = [0.16, 1, 0.3, 1] as const
const DURATION = 0.62

interface SiteShellProps {
	children: ReactNode
	mainId: string
}

export function SiteShell({ children, mainId }: SiteShellProps) {
	return (
		<div className="min-h-dvh bg-kumo-canvas text-kumo-default">
			<a
				className="
					sr-only z-50 rounded-md bg-kumo-contrast px-4 py-2 text-kumo-inverse
					focus:not-sr-only focus:fixed focus:top-4 focus:left-4
				"
				href={`#${mainId}`}
			>
				Skip to content
			</a>
			<SiteHeader />
			{children}
			<SiteFooter />
		</div>
	)
}

// Icon is 32px; 8px gap to the wordmark. The mark is out of flow so both the
// icon entrance and the wordmark shift share one transition — the wordmark is
// pushed by animating its padding, not by waiting for a layout reflow after
// the icon finishes.
const BRAND_ICON = 32
const BRAND_GAP = 8
const BRAND_SHIFT = BRAND_ICON + BRAND_GAP

export function BrandLink({ showIcon = true }: { showIcon?: boolean }) {
	const reduceMotion = useReducedMotion()
	const transition = { duration: reduceMotion ? 0 : DURATION, ease: EASE }

	return (
		<a
			className="
				relative flex min-h-11 items-center rounded-md text-kumo-strong
				focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-kumo-focus
			"
			href="/"
		>
			{/*
			  On the landing page the hero already carries the app icon, so the
			  header mark only slides in once that hero has left the viewport —
			  same mark, never two at once. Legal pages have no hero and keep the
			  icon always visible.

			  The icon is absolutely positioned (no layout width of its own). Its
			  entrance is x + blur + opacity; the wordmark's paddingLeft runs on
			  the same curve so the text is pushed over in lockstep, not after.
			*/}
			<span className="pointer-events-none absolute inset-y-0 left-0 flex items-center">
				<AnimatePresence initial={false}>
					{showIcon
						? (
								<motion.img
									exit={reduceMotion
										? { opacity: 0 }
										: { filter: 'blur(8px)', opacity: 0, x: -16 }}
									initial={reduceMotion
										? false
										: { filter: 'blur(8px)', opacity: 0, x: -16 }}
									alt=""
									animate={{ filter: 'blur(0px)', opacity: 1, x: 0 }}
									className="size-8"
									height={BRAND_ICON}
									key="brand-icon"
									src={dashAppIconUrl}
									transition={transition}
									width={BRAND_ICON}
								/>
							)
						: null}
				</AnimatePresence>
			</span>
			<motion.span
				animate={{ paddingLeft: showIcon ? BRAND_SHIFT : 0 }}
				className="text-lg font-semibold"
				initial={false}
				transition={transition}
			>
				Dash
			</motion.span>
		</a>
	)
}

function SiteHeader() {
	const showBrandIcon = useBrandIconAfterHero()

	return (
		<header className="sticky top-0 z-40 border-b border-kumo-hairline bg-kumo-base">
			<div className="
				mx-auto flex min-h-16 w-full max-w-7xl items-center justify-between gap-6 px-5
				sm:px-8
			"
			>
				<BrandLink showIcon={showBrandIcon} />
				<div className="flex items-center justify-end gap-1">
					<nav
						className="
							hidden items-center gap-1
							sm:flex
						"
						aria-label="Primary"
					>
						<Link className="flex min-h-11 items-center rounded-md px-3 text-sm text-kumo-default" href="#features" variant="plain">
							Features
						</Link>
						<Link className="flex min-h-11 items-center rounded-md px-3 text-sm text-kumo-default" href="#app" variant="plain">
							App
						</Link>
						<Link className="flex min-h-11 items-center rounded-md px-3 text-sm text-kumo-default" href="#security" variant="plain">
							Security
						</Link>
					</nav>
					<LinkButton
						aria-label="GitHub"
						className="pressable"
						href="https://github.com/withxat/Dash"
						icon={GithubLogoIcon}
						shape="square"
						size="base"
						variant="secondary"
						external
					/>
				</div>
			</div>
		</header>
	)
}

/**
 * True once the landing hero has scrolled out (or when there is no hero, as
 * on legal pages). The header brand icon follows this so it does not compete
 * with the large mark still on screen.
 */
function useBrandIconAfterHero() {
	// Avoid a one-frame flash of the mark over the landing hero: the home path
	// starts hidden and the observer turns it on after the hero leaves. Legal
	// routes keep the mark from the first paint.
	const [showIcon, setShowIcon] = useState(() => {
		if (typeof window === 'undefined') {
			return true
		}
		const path = window.location.pathname.replace(/\/$/, '') || '/'
		return path !== '/'
	})

	useEffect(() => {
		const hero = document.querySelector<HTMLElement>('[data-od-id="dash-hero"]')
		// Legal routes never mount a hero; the path-based initial state already
		// shows the mark. Only the landing page needs the observer.
		if (!hero) {
			return
		}

		const observer = new IntersectionObserver(
			([entry]) => {
				// Any visible fraction of the hero keeps the header mark away.
				setShowIcon(!entry.isIntersecting)
			},
			// The sticky header covers the top ~64px; treat the hero as gone
			// once it has fully cleared that band.
			{ rootMargin: '-64px 0px 0px 0px', threshold: 0 },
		)

		observer.observe(hero)
		return () => observer.disconnect()
	}, [])

	return showIcon
}

function SiteFooter() {
	return (
		<footer className="border-t border-kumo-hairline bg-kumo-base">
			<div className="
				mx-auto flex w-full max-w-7xl flex-col gap-5 px-5 py-8 text-sm text-kumo-subtle
				sm:flex-row sm:items-center sm:justify-between sm:px-8
			"
			>
				<div className="flex items-center gap-3">
					<img alt="" className="size-7" height="28" loading="lazy" src={dashAppIconUrl} width="28" />
					<span>Dash for Cloudflare, built by Xat.</span>
				</div>
				<nav aria-label="Footer" className="flex flex-wrap items-center gap-x-5 gap-y-2">
					<Link className="flex min-h-11 items-center" href="/privacy" variant="plain">Privacy</Link>
					<Link className="flex min-h-11 items-center" href="/terms" variant="plain">Terms</Link>
					<Link className="flex min-h-11 items-center" href="mailto:i@xat.sh" variant="plain">Contact</Link>
				</nav>
			</div>
		</footer>
	)
}
