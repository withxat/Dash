import type { Components } from 'react-markdown'

import { Link } from '@cloudflare/kumo/components/link'
import { Text } from '@cloudflare/kumo/components/text'
import { useEffect } from 'react'
import ReactMarkdown from 'react-markdown'

import { SiteShell } from './site-shell'

interface LegalPageProps {
	document: string
	title: string
}

const markdownComponents: Components = {
	a: ({ children, href }) => <Link href={href ?? '#'}>{children}</Link>,
	code: ({ children }) => (
		<code className="rounded-sm bg-kumo-recessed px-1.5 py-0.5 font-mono text-[0.9em] text-kumo-default">
			{children}
		</code>
	),
	h1: ({ children }) => <Text as="h1" variant="heading1">{children}</Text>,
	h2: ({ children }) => (
		<div className="mt-10">
			<Text as="h2" variant="heading2">{children}</Text>
		</div>
	),
	li: ({ children }) => (
		<li className="
			pl-1 text-pretty
			marker:text-kumo-brand
		"
		>
			{children}
		</li>
	),
	p: ({ children }) => <p className="mt-3 max-w-[65ch] text-sm/6 text-pretty text-kumo-subtle">{children}</p>,
	strong: ({ children }) => <strong className="font-medium text-kumo-default">{children}</strong>,
	ul: ({ children }) => <ul className="mt-3 max-w-[65ch] list-disc space-y-2 pl-5 text-sm/6 text-kumo-subtle">{children}</ul>,
}

export function LegalPage({ document, title }: LegalPageProps) {
	useEffect(() => {
		const previousTitle = window.document.title
		window.document.title = `${title} | Dash for Cloudflare`
		return () => {
			window.document.title = previousTitle
		}
	}, [title])

	return (
		<SiteShell mainId="legal-content">
			<main
				className="
					mx-auto w-full max-w-3xl px-5 py-14
					sm:px-8 sm:py-20
				"
				id="legal-content"
			>
				<div className="mb-8 flex items-center gap-2 text-sm text-kumo-subtle">
					<Link href="/" variant="plain">Dash</Link>
					<span aria-hidden>/</span>
					<span>{title}</span>
				</div>
				<article className="
					rounded-xl bg-kumo-base p-5 ring ring-kumo-line
					sm:p-8
				"
				>
					<ReactMarkdown components={markdownComponents}>
						{document}
					</ReactMarkdown>
				</article>
			</main>
		</SiteShell>
	)
}
