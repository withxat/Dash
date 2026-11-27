import type { ReactNode, SVGProps } from 'react'

import { dashAppIconUrl } from './brand-assets'
import { DitheredWordmarkCanvas } from './dither-canvas'
import { useLocale } from './i18n'

/**
 * Official GitHub Invertocat mark (Octicons `mark-github`), MIT-licensed.
 * @see https://github.com/primer/octicons
 */
export function GitHubMarkIcon({ className, ...props }: SVGProps<SVGSVGElement>) {
	return (
		<svg
			aria-hidden="true"
			className={className ?? 'size-4'}
			fill="currentColor"
			height="16"
			viewBox="0 0 16 16"
			width="16"
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
	const { t } = useLocale()
	return (
		<div className="flex min-h-dvh flex-col bg-dash-paper text-dash-ink">
			<a
				className="
					sr-only z-50 rounded-md bg-dash-ink px-4 py-2 text-sm text-white
					focus:not-sr-only focus:fixed focus:top-4 focus:left-4
				"
				href={`#${mainId}`}
			>
				{t.skipToContent}
			</a>
			<SiteHeader />
			<div className="flex-1">{children}</div>
			<SiteFooter />
		</div>
	)
}

export function BrandLink() {
	return (
		<a
			className="
				flex min-h-11 items-center gap-2.5 rounded-md text-dash-ink
				focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-dash-accent-deep
			"
			href="/"
		>
			<img
				alt=""
				className="size-6 rounded-[6px] shadow-[0_1px_2px_rgb(15_15_14/0.14)]"
				height="24"
				src={dashAppIconUrl}
				width="24"
			/>
			<span className="text-[15px] font-medium tracking-[-0.02em]">Dash</span>
		</a>
	)
}

function SiteHeader() {
	const { locale, t, toggleLocale } = useLocale()
	return (
		<header className="w-full">
			<div className="
				mx-auto flex h-20 w-full max-w-[1200px] items-center justify-between gap-6 px-5
				sm:px-8
			"
			>
				<BrandLink />
				<nav
					className="
						flex items-center gap-5 text-[13px] text-dash-muted
						sm:gap-8
					"
					aria-label="Primary"
				>
					<a
						className="
							hidden transition-colors
							hover:text-dash-ink
							sm:inline
						"
						href="/#surfaces"
					>
						{t.navSurfaces}
					</a>
					<a
						className="
							hidden transition-colors
							hover:text-dash-ink
							sm:inline
						"
						href="/#architecture"
					>
						{t.navArchitecture}
					</a>
					<a
						className="
							transition-colors
							hover:text-dash-ink
						"
						href="/privacy"
					>
						{t.navPrivacy}
					</a>
					<button
						className="
							cursor-pointer text-[13px] text-dash-faint transition-colors
							hover:text-dash-ink
							focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-dash-accent-deep
						"
						aria-label={locale === 'en' ? '切换到中文' : 'Switch to English'}
						onClick={toggleLocale}
						type="button"
					>
						{locale === 'en' ? '中文' : 'EN'}
					</button>
					<a
						className="
							inline-flex items-center gap-1.5 font-medium text-dash-ink transition-opacity
							hover:opacity-65
						"
						href="https://github.com/withxat/Dash"
						rel="noopener noreferrer"
						target="_blank"
					>
						<span>GitHub</span>
						<span aria-hidden="true" className="text-[11px] text-dash-faint">↗</span>
					</a>
				</nav>
			</div>
		</header>
	)
}

function SiteFooter() {
	const { t } = useLocale()
	return (
		<footer className="
			w-full pt-4 pb-6
			sm:pb-10
		"
		>
			<div className="
				mx-auto max-w-[1200px] px-5
				sm:px-8
			"
			>
				<div className="relative overflow-hidden rounded-[28px] bg-dash-gallery">
					<DitheredWordmarkCanvas className="pointer-events-none absolute inset-0 size-full select-none" />

					<div className="
						relative z-10 grid gap-10 px-6 pt-10 pb-8
						sm:px-12 sm:pt-12 sm:pb-10
						lg:grid-cols-12 lg:gap-8
					"
					>
						<div className="lg:col-span-5">
							<div className="flex items-center gap-2.5">
								<img
									alt=""
									className="size-6 rounded-[6px] shadow-[0_1px_2px_rgb(15_15_14/0.14)]"
									height="24"
									loading="lazy"
									src={dashAppIconUrl}
									width="24"
								/>
								<span className="text-[15px] font-medium tracking-[-0.02em] text-dash-ink">
									Dash for Cloudflare
								</span>
							</div>
							<p className="mt-3.5 max-w-[34ch] text-[13px]/[1.65] text-pretty text-dash-muted">
								{t.footerBlurbBefore}
								{' '}
								<a
									className="
										font-medium text-dash-ink underline decoration-black/20 underline-offset-3 transition-colors
										hover:decoration-dash-ink
									"
									href="https://xat.sh"
									rel="author me noopener noreferrer"
									target="_blank"
								>
									Xat
								</a>
								{t.footerBlurbAfter}
							</p>
							<p className="mt-4 font-mono text-[11px] tracking-[0.04em] text-dash-faint">
								{t.footerMeta}
							</p>
						</div>

						<nav
							className="
								grid grid-cols-2 gap-8 text-[13px]
								sm:grid-cols-3
								lg:col-span-7 lg:justify-items-end
							"
							aria-label="Footer"
						>
							<div>
								<p className="font-mono text-[10px] tracking-[0.12em] text-dash-faint uppercase">
									{t.footerColProduct}
								</p>
								<ul className="mt-3.5 space-y-2.5 text-dash-muted">
									<li>
										<a
											className="
												transition-colors
												hover:text-dash-ink
											"
											href="/#surfaces"
										>
											{t.navSurfaces}
										</a>
									</li>
									<li>
										<a
											className="
												transition-colors
												hover:text-dash-ink
											"
											href="/#architecture"
										>
											{t.navArchitecture}
										</a>
									</li>
									<li>
										<a
											className="
												inline-flex items-center gap-1 transition-colors
												hover:text-dash-ink
											"
											href="https://github.com/withxat/Dash"
											rel="noopener noreferrer"
											target="_blank"
										>
											<span>GitHub</span>
											<span aria-hidden="true" className="text-[10px] text-dash-faint">↗</span>
										</a>
									</li>
									<li>
										<a
											className="
												font-mono text-[12px] transition-colors
												hover:text-dash-ink
											"
											href="/llms.txt"
										>
											llms.txt
										</a>
									</li>
								</ul>
							</div>

							<div>
								<p className="font-mono text-[10px] tracking-[0.12em] text-dash-faint uppercase">
									{t.footerColLegal}
								</p>
								<ul className="mt-3.5 space-y-2.5 text-dash-muted">
									<li>
										<a
											className="
												transition-colors
												hover:text-dash-ink
											"
											href="/privacy"
										>
											{t.legalPrivacyTitle}
										</a>
									</li>
									<li>
										<a
											className="
												transition-colors
												hover:text-dash-ink
											"
											href="/terms"
										>
											{t.legalTermsTitle}
										</a>
									</li>
								</ul>
							</div>

							<div>
								<p className="font-mono text-[10px] tracking-[0.12em] text-dash-faint uppercase">
									{t.footerColElsewhere}
								</p>
								<ul className="mt-3.5 space-y-2.5 text-dash-muted">
									<li>
										<a
											className="
												inline-flex items-center gap-1 transition-colors
												hover:text-dash-ink
											"
											href="https://xat.sh"
											rel="author me noopener noreferrer"
											target="_blank"
										>
											<span>xat.sh</span>
											<span aria-hidden="true" className="text-[10px] text-dash-faint">↗</span>
										</a>
									</li>
									<li>
										<a
											className="
												inline-flex items-center gap-1 transition-colors
												hover:text-dash-ink
											"
											href="https://x.com/withxat"
											rel="me noopener noreferrer"
											target="_blank"
										>
											<span>X</span>
											<span aria-hidden="true" className="text-[10px] text-dash-faint">↗</span>
										</a>
									</li>
									<li>
										<a
											className="
												transition-colors
												hover:text-dash-ink
											"
											href="mailto:i@xat.sh"
										>
											i@xat.sh
										</a>
									</li>
								</ul>
							</div>
						</nav>
					</div>

					<div
						className="
							h-[108px]
							sm:h-[208px]
							lg:h-[310px]
						"
						aria-hidden="true"
					/>
				</div>
			</div>
		</footer>
	)
}
