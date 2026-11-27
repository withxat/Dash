import type { Components } from 'react-markdown'

import { useEffect } from 'react'
import ReactMarkdown from 'react-markdown'

import { useLocale } from './i18n'
import { SiteShell } from './site-shell'

const markdownComponents: Components = {
	a: ({ children, href }) => (
		<a
			className="
				font-medium text-dash-ink underline decoration-black/25 underline-offset-4 transition-colors
				hover:decoration-dash-ink
			"
			href={href}
			rel={href?.startsWith('http') ? 'noopener noreferrer' : undefined}
			target={href?.startsWith('http') ? '_blank' : undefined}
		>
			{children}
		</a>
	),
	code: ({ children }) => (
		<code className="rounded-sm bg-dash-gallery px-1.5 py-0.5 font-mono text-[13px] text-dash-ink">
			{children}
		</code>
	),
	h1: ({ children }) => (
		<h1 className="mb-4 text-[clamp(2rem,4vw,2.75rem)]/[1.06] font-medium tracking-[-0.038em] text-dash-ink">
			{children}
		</h1>
	),
	h2: ({ children }) => (
		<h2 className="mt-12 mb-4 border-t border-black/8 pt-8 text-[17px]/[1.35] font-medium tracking-[-0.015em] text-dash-ink">
			{children}
		</h2>
	),
	li: ({ children }) => (
		<li className="text-[15px]/[1.7] text-dash-muted">{children}</li>
	),
	p: ({ children }) => (
		<p className="
			mb-4 text-[15px]/[1.75] text-dash-muted
			last:mb-0
		"
		>
			{children}
		</p>
	),
	strong: ({ children }) => (
		<strong className="font-medium text-dash-ink">{children}</strong>
	),
	ul: ({ children }) => (
		<ul className="mb-5 list-disc space-y-2.5 pl-5">{children}</ul>
	),
}

interface LegalPageProps {
	canonicalPath: string
	description: string
	document: string
	title: string
}

export function LegalPage({ canonicalPath, description, document: markdown, title }: LegalPageProps) {
	const { t } = useLocale()
	useEffect(() => {
		const pageTitle = `${title} · Dash for Cloudflare`
		const canonicalUrl = `https://dash.xat.sh${canonicalPath}`
		window.document.title = pageTitle

		const canonicalLink = window.document.querySelector('link[rel="canonical"]')
		canonicalLink?.setAttribute('href', canonicalUrl)

		const descriptionMeta = window.document.querySelector('meta[name="description"]')
		descriptionMeta?.setAttribute('content', description)

		const ogUrlMeta = window.document.querySelector('meta[property="og:url"]')
		ogUrlMeta?.setAttribute('content', canonicalUrl)

		const ogTitleMeta = window.document.querySelector('meta[property="og:title"]')
		ogTitleMeta?.setAttribute('content', pageTitle)
	}, [canonicalPath, description, title])

	return (
		<SiteShell mainId="legal-content">
			<main
				className="
					mx-auto max-w-[1200px] px-5 pt-10 pb-24
					sm:px-8 sm:pt-16 sm:pb-32
				"
				id="legal-content"
			>
				<div className="
					grid gap-10
					lg:grid-cols-12
				"
				>
					<div className="lg:col-span-3">
						<div className="lg:sticky lg:top-12">
							<a
								className="
									inline-flex items-center gap-1.5 text-[13px] text-dash-faint transition-colors
									hover:text-dash-ink
								"
								href="/"
							>
								<span aria-hidden="true">←</span>
								<span>{t.legalBack}</span>
							</a>
							<p className="mt-6 font-mono text-[11px] tracking-[0.06em] text-dash-faint uppercase">
								{title}
							</p>
							{t.legalEnglishNote && (
								<p className="mt-2 text-[12px]/[1.6] text-dash-faint">
									{t.legalEnglishNote}
								</p>
							)}
						</div>
					</div>
					<article className="
						max-w-2xl
						lg:col-span-9
					"
					>
						<ReactMarkdown components={markdownComponents}>
							{markdown}
						</ReactMarkdown>
					</article>
				</div>
			</main>
		</SiteShell>
	)
}
