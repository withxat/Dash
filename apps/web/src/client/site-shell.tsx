import type { ReactNode, SVGProps } from 'react'

import { LinkButton } from '@cloudflare/kumo/components/button'
import { Link } from '@cloudflare/kumo/components/link'

import { dashAppIconUrl } from './brand-assets'

/**
 * Official GitHub Invertocat mark (Octicons `mark-github`), MIT-licensed.
 * Prefer this over third-party icon packs so the header mark matches the brand.
 * @see https://github.com/primer/octicons
 */
function GitHubMarkIcon({ className, ...props }: SVGProps<SVGSVGElement>) {
	return (
		<svg
			aria-hidden="true"
			className={className ?? 'size-[18px]'}
			fill="currentColor"
			height="18"
			viewBox="0 0 16 16"
			width="18"
			xmlns="http://www.w3.org/2000/svg"
			{...props}
		>
			<path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z" />
		</svg>
	)
}

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
					icon={<GitHubMarkIcon />}
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
