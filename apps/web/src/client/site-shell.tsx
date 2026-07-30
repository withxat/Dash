import type { ReactNode } from 'react'

import { LinkButton } from '@cloudflare/kumo/components/button'
import { Link } from '@cloudflare/kumo/components/link'
import { GithubLogoIcon } from '@phosphor-icons/react/dist/ssr/GithubLogo'

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
	// Single-screen landing: the brand mark stays in the header. There is no
	// competing hero lockup and no in-page section nav to jump to.
	return (
		<header className="sticky top-0 z-40 border-b border-kumo-hairline bg-kumo-base">
			<div className="
				mx-auto flex min-h-16 w-full max-w-7xl items-center justify-between gap-6 px-5
				sm:px-8
			"
			>
				<BrandLink />
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
