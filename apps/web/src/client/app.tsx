import { PrivacyPage } from './privacy-page'

function pathIsPrivacy(pathname: string): boolean {
	return pathname === '/privacy' || pathname === '/privacy/'
}

export function App() {
	if (pathIsPrivacy(window.location.pathname)) {
		return <PrivacyPage />
	}

	return <LandingPage />
}

function LandingPage() {
	return (
		<div className="relative min-h-dvh overflow-hidden">
			<div
				className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_20%_0%,#ffe4c7_0%,transparent_55%),radial-gradient(ellipse_at_90%_10%,#ffebd6_0%,transparent_45%),linear-gradient(180deg,#fff7ef_0%,#ffffff_55%,#fff7ef_100%)]"
				aria-hidden
			/>
			<div
				className="pointer-events-none absolute -top-24 left-1/2 size-112 -translate-x-1/2 animate-glow-drift rounded-full bg-dash-accent/25 blur-3xl"
				aria-hidden
			/>
			<div
				className="pointer-events-none absolute top-40 -right-16 size-64 animate-drift rounded-full bg-dash-peach/80 blur-2xl"
				style={{ animationDelay: '-3s' }}
				aria-hidden
			/>

			<header className="
				relative z-10 mx-auto flex w-full max-w-5xl items-center justify-between px-6 pt-8
				sm:px-10
			"
			>
				<a className="font-display text-2xl font-semibold tracking-tight text-dash-ink" href="/">
					Dash
				</a>
				<a
					className="
						text-sm font-medium text-dash-ink/60 transition-colors
						hover:text-dash-ink
					"
					href="/privacy"
				>
					Privacy
				</a>
			</header>

			<main className="
				relative z-10 mx-auto flex min-h-[calc(100dvh-7rem)] w-full max-w-5xl flex-col justify-center px-6
				py-16
				sm:px-10 sm:pt-20
			"
			>
				<p className="animate-rise font-sans text-sm font-medium tracking-[0.18em] text-dash-accent uppercase">
					For Cloudflare
				</p>
				<h1 className="
					mt-4 max-w-3xl animate-rise-delay-1 font-display text-5xl leading-[1.05] font-semibold tracking-tight text-dash-ink
					sm:text-6xl
					md:text-7xl
				"
				>
					Your Cloudflare account, in your pocket.
				</h1>
				<p className="
					mt-6 max-w-xl animate-rise-delay-2 text-lg/relaxed text-dash-ink/70
					sm:text-xl
				"
				>
					Dash is a native iPhone client for zones, Workers, R2, and the rest of your stack —
					signed in with OAuth, kept on-device.
				</p>

				<div className="mt-10 flex animate-rise-delay-2 flex-wrap items-center gap-4">
					<a
						className="
							inline-flex h-12 items-center justify-center rounded-full bg-dash-ink px-7 text-sm font-semibold text-white
							transition-[transform,background-color] duration-200
							hover:bg-dash-ink/90
							active:scale-[0.98]
						"
						href="https://apps.apple.com/search?term=Dash%20for%20Cloudflare"
					>
						View on the App Store
					</a>
					<a
						className="
							inline-flex h-12 items-center justify-center rounded-full border border-dash-ink/15 bg-white/60 px-7 text-sm
							font-semibold text-dash-ink backdrop-blur-sm transition-[transform,background-color] duration-200
							hover:bg-white
							active:scale-[0.98]
						"
						href="https://github.com/withxat/Dash"
					>
						GitHub
					</a>
				</div>
			</main>

			<footer className="
				relative z-10 mx-auto flex w-full max-w-5xl items-center justify-between px-6 pb-8
				text-sm text-dash-ink/45
				sm:px-10
			"
			>
				<span>© 2026 Xat</span>
				<a
					className="
						transition-colors
						hover:text-dash-ink/70
					"
					href="mailto:i@xat.sh"
				>
					i@xat.sh
				</a>
			</footer>
		</div>
	)
}
