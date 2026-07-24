import type { ReactNode } from 'react'

import { LinkButton } from '@cloudflare/kumo/components/button'
import { Link } from '@cloudflare/kumo/components/link'

import { dashAppIconUrl } from './brand-assets'

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

export function BrandLink() {
	return (
		<a
			className="
				flex min-h-11 items-center gap-2 rounded-md text-kumo-strong
				focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-kumo-focus
			"
			href="/"
		>
			<img alt="" className="size-8" height="32" src={dashAppIconUrl} width="32" />
			<span className="text-lg font-semibold">Dash</span>
		</a>
	)
}

function SiteHeader() {
	return (
		<header className="sticky top-0 z-40 border-b border-kumo-hairline bg-kumo-base">
			<div className="
				mx-auto flex min-h-16 w-full max-w-7xl items-center justify-between gap-6 px-5
				sm:px-8
			"
			>
				<BrandLink />
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
						className="min-h-11 pressable"
						href="https://github.com/withxat/Dash"
						size="sm"
						variant="secondary"
						external
					>
						Source
					</LinkButton>
				</div>
			</div>
		</header>
	)
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
