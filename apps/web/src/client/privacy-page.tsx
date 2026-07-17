const sections = [
	{
		body: 'Nothing by default. Dash contains no analytics, no crash-reporting SDKs, no tracking, no advertising identifiers, and no third-party frameworks. We do not operate a general-purpose backend that stores your account data.',
		title: 'What Dash collects',
	},
	{
		body: 'OAuth tokens are issued by Cloudflare when you sign in and are stored only in your device Keychain. API responses stay on device for the session. The HTTPS relay at dash.xat.sh redirects the OAuth callback to the app and never stores credentials or the PKCE verifier.',
		title: 'Where your data lives',
	},
	{
		body: 'Questions about privacy: i@xat.sh',
		title: 'Contact',
	},
] as const

export function PrivacyPage() {
	return (
		<div className="min-h-dvh bg-dash-cream">
			<header className="
				mx-auto flex w-full max-w-3xl items-center justify-between px-6 pt-8
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
					href="/"
				>
					Home
				</a>
			</header>

			<main className="
				mx-auto w-full max-w-3xl px-6 py-16
				sm:px-10
			"
			>
				<p className="text-sm font-medium tracking-[0.18em] text-dash-accent uppercase">
					Legal
				</p>
				<h1 className="
					mt-3 font-display text-4xl font-semibold tracking-tight text-dash-ink
					sm:text-5xl
				"
				>
					Privacy Policy
				</h1>
				<p className="mt-4 text-dash-ink/60">
					Effective July 16, 2026. Full policy also ships inside the iOS app.
				</p>

				<div className="mt-12 space-y-10">
					{sections.map(section => (
						<section key={section.title}>
							<h2 className="font-display text-2xl font-semibold text-dash-ink">
								{section.title}
							</h2>
							<p className="mt-3 text-base/relaxed text-dash-ink/75">
								{section.body}
							</p>
						</section>
					))}
				</div>
			</main>
		</div>
	)
}
