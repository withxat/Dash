import type { TourStop } from './motion-primitives'

import { Badge } from '@cloudflare/kumo/components/badge'
import { LinkButton } from '@cloudflare/kumo/components/button'
import { Link } from '@cloudflare/kumo/components/link'

import { dashAppIconUrl } from './brand-assets'
import { Parallax, Reveal, Stagger, StaggerItem, StickyTour } from './motion-primitives'
import { SiteShell } from './site-shell'

// GitHub is the only public destination that exists today. Keep the label and
// the destination aligned, never publish a placeholder App Store URL, and use
// this one label everywhere the page asks for the same thing.
const PRIMARY_CTA_HREF = 'https://github.com/withxat/Dash'
const PRIMARY_CTA_LABEL = 'Read the source on GitHub'

// Real device captures from the shipping app, stored as WebP at the native
// iPhone 16 Pro display resolution (a raw capture is ~1.7 MB, far too heavy
// for the page). Bump the query version when a capture is replaced.
const SHOT_VERSION = '?v=1'
const SHOT_WIDTH = 1206
const SHOT_HEIGHT = 2622
const IPHONE_16_PRO_FRAME = '/device-frames/iphone-16-pro-desert-titanium.svg?v=2'

interface ScreenshotSpec {
	alt: string
	src: string
}

const zoneShot: ScreenshotSpec = {
	alt: 'A zone open in Dash, showing its nameservers and quick actions for DNS, HTTP traffic, Web Analytics, WAF, cache, and settings',
	src: `/screens/zone.webp${SHOT_VERSION}`,
}

const watchtowerShot: ScreenshotSpec = {
	alt: 'The Dash Watchtower screen, charting web traffic, CPU time, and Worker invocations over the last 24 hours',
	src: `/screens/watchtower.webp${SHOT_VERSION}`,
}

const pagesShot: ScreenshotSpec = {
	alt: 'A Pages project in Dash, showing a build outcome chart and a deployment history with commit messages and build results',
	src: `/screens/pages.webp${SHOT_VERSION}`,
}

const r2Shot: ScreenshotSpec = {
	alt: 'An R2 bucket open in Dash, listing virtual folders and files with per-format glyphs',
	src: `/screens/r2.webp${SHOT_VERSION}`,
}

interface LabelledItem {
	label: string
	text: string
}

const rollbackSteps: LabelledItem[] = [
	{
		label: 'Pick',
		text: 'Choose any earlier deployment from the history. The live one is badged, so there is no ambiguity about what you are leaving.',
	},
	{
		label: 'Confirm',
		text: 'Dash states that this sends all traffic to the deployment you picked. Gradual splits are unsupported on purpose: a partial cut-over you cannot watch from a phone is worse than a whole one you can.',
	},
	{
		label: 'Watch',
		text: 'The write goes to the Cloudflare API, which stays the final boundary. If Cloudflare refuses, the control reverts and says why.',
	},
]

// The argument for a native client, made with the parts of it that run when the
// app is not the thing in front of you.
const osSurfaces: LabelledItem[] = [
	{
		label: 'Live Activities',
		text: 'A Pages build in progress runs on the lock screen. Dash keeps it current in the foreground and continues in the background when iOS grants the time. Background refresh is best effort, so the foreground view stays authoritative.',
	},
	{
		label: 'Push alerts',
		text: 'Cloudflare alerts arrive as real notifications. Opening one lands on the screen the alert is about, not at the top of the app.',
	},
	{
		label: 'Home screen widget',
		text: 'It counts one number: Cloudflare deliveries you have not read on this iPhone. Cloudflare publishes no read state, so unread is tracked locally and ignoring an alert is reversible.',
	},
	{
		label: 'Siri and Shortcuts',
		text: 'Purge Cache, Under Attack, Development Mode, Upload to R2, and Open Watchtower are App Intents. Say them, or wire them into your own automations.',
	},
	{
		label: 'Share extension',
		text: 'Share an image from any app into your last used R2 bucket. The public URL is on the clipboard when it finishes.',
	},
]

const relayFacts: LabelledItem[] = [
	{ label: 'Redirects OAuth', text: 'It answers the HTTPS callback and hands you back to the app.' },
	{ label: 'Forwards alerts', text: 'It passes mapped Cloudflare alert webhooks to APNs, deep link included.' },
	{ label: 'Stores nothing', text: 'No KV, no D1, no Durable Objects. Nothing of yours has anywhere to sit.' },
	{ label: 'Receives no secrets', text: 'Not your Cloudflare credentials, not your tokens, not the PKCE verifier.' },
	{ label: 'Keeps no record', text: 'No query strings, no device tokens, no alert payloads. Only APNs status codes.' },
	{ label: 'Holds nothing you cannot revoke', text: 'Push setup lives in your own Cloudflare account. Delete it there and delivery stops.' },
]

export function LandingPage() {
	return (
		<SiteShell mainId="main-content">
			<main id="main-content">
				<Hero />
				<ZoneStage />
				<IncidentTour />
				<OperatingSystemSurfaces />
				<RelaySection />
				<FinalCallToAction />
			</main>
		</SiteShell>
	)
}

function Hero() {
	return (
		<section className="overflow-hidden bg-kumo-base" data-od-id="dash-hero">
			<Stagger
				className="
					mx-auto w-full max-w-7xl px-5 pt-14 pb-16
					sm:px-8 sm:pt-20 sm:pb-24
				"
				on="load"
			>
				<div className="
					grid gap-12
					lg:grid-cols-12 lg:items-end lg:gap-x-8
				"
				>
					<div className="lg:col-span-8">
						<StaggerItem>
							<Badge variant="orange">Open source. App Store release in progress.</Badge>
						</StaggerItem>
						<StaggerItem>
							<h1 className="mt-6 max-w-[11ch] text-[clamp(3.5rem,7.5vw,6.5rem)]/[0.9] font-semibold tracking-[-0.04em] text-balance text-kumo-strong">
								Run Cloudflare beyond the desk.
							</h1>
						</StaggerItem>
					</div>

					<StaggerItem className="lg:col-span-4">
						<img
							alt=""
							className="size-16 rounded-[14px]"
							height="64"
							src={dashAppIconUrl}
							width="64"
						/>
						<p className="mt-6 max-w-md text-base/6 text-pretty text-kumo-subtle">
							Purge a cache, roll back a deploy, and watch the traffic recover.
							Zones, Workers, Pages, R2, and KV, in a native iPhone app.
						</p>
						<div className="mt-8 flex flex-wrap items-center gap-x-2 gap-y-1">
							<LinkButton
								className="pressable"
								href={PRIMARY_CTA_HREF}
								size="lg"
								variant="primary"
								external
							>
								{PRIMARY_CTA_LABEL}
							</LinkButton>
							<Link
								className="flex min-h-11 items-center rounded-md px-3 text-sm font-medium"
								href="#app"
								variant="plain"
							>
								See the app
							</Link>
						</div>
					</StaggerItem>
				</div>
			</Stagger>
		</section>
	)
}

function ZoneStage() {
	return (
		<div
			className="scroll-mt-20 overflow-hidden bg-kumo-contrast text-kumo-inverse"
			data-od-id="zone-stage"
			id="app"
		>
			<div className="
				mx-auto w-full max-w-7xl px-5 pt-16
				sm:px-8 sm:pt-20
			"
			>
				<Reveal>
					<h2 className="
						mx-auto max-w-[20ch] text-center text-3xl/[1.05] font-semibold tracking-[-0.022em] text-balance
						sm:text-4xl/[1.02]
					"
					>
						The first minute, on one screen.
					</h2>
					<p className="mx-auto mt-6 max-w-xl text-center text-sm/6 text-pretty text-kumo-inverse/60">
						Purge a single URL or purge everything. Turn on Under Attack mode. Edit
						a DNS record and its proxy status. See what the WAF is blocking and
						where it came from. Nameservers and plan sit on the same screen, in
						mono, for the moment somebody asks you to read them out.
					</p>
				</Reveal>
			</div>

			{/* The device rises out of the fold as the band scrolls past. One
			    entrance, not a perpetual float. Bottom padding keeps the bezel
			    off the contrast band's hard edge. */}
			<Parallax
				className="
					mt-14 px-5 pb-16
					sm:mt-16 sm:px-8 sm:pb-20
				"
				depth={28}
			>
				<AppScreenshot screenshot={zoneShot} size="hero" priority />
			</Parallax>
		</div>
	)
}

function IncidentTour() {
	// One device, three surfaces: act, verify, undo. The pin is the argument.
	const stops: TourStop[] = [
		{
			content: (
				<>
					<h3 className="
						max-w-[16ch] text-3xl/[1.05] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-4xl/[1.02]
					"
					>
						Then you find out whether it worked.
					</h3>
					<p className="mt-6 max-w-md text-base/6 text-pretty text-kumo-subtle">
						A fix is a guess until the lines move. Watchtower charts traffic, cache
						rate, request errors, Worker invocations, and CPU time over 24 hours,
						7 days, or 30 days, in a card layout you arrange once and keep.
					</p>
					<p className="mt-4 max-w-md text-base/6 text-pretty text-kumo-subtle">
						The numbers are Cloudflare's, drawn the way Cloudflare reports them.
						Dash publishes no health verdict of its own. A tool that raises an
						alarm your provider never raised is training you to ignore it.
					</p>
				</>
			),
			id: 'verify',
			media: <AppScreenshot screenshot={watchtowerShot} size="standard" />,
		},
		{
			content: (
				<>
					<h3 className="
						max-w-[16ch] text-3xl/[1.05] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-4xl/[1.02]
					"
					>
						Go back to the deployment that was fine.
					</h3>
					<p className="mt-6 max-w-md text-base/6 text-pretty text-kumo-subtle">
						Workers and Pages both carry their whole deployment history, not just
						what is live. Each one shows its commit message and build outcome, so
						finding the last good build is a look rather than a search.
					</p>
					<dl className="mt-10 max-w-md">
						{rollbackSteps.map(({ label, text }) => (
							<div
								className="
									border-t border-kumo-hairline py-5
									last:border-b
								"
								key={label}
							>
								<dt className="text-sm font-medium text-kumo-strong">{label}</dt>
								<dd className="mt-1.5 text-sm/6 text-pretty text-kumo-subtle">{text}</dd>
							</div>
						))}
					</dl>
				</>
			),
			id: 'undo',
			media: <AppScreenshot screenshot={pagesShot} size="standard" />,
		},
		{
			content: (
				<>
					<h3 className="
						max-w-[16ch] text-3xl/[1.05] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-4xl/[1.02]
					"
					>
						Not every fix is a switch.
					</h3>
					<p className="mt-6 max-w-md text-base/6 text-pretty text-kumo-subtle">
						Some of them are a file. R2 browses like a small file manager: buckets
						open into folders, images carry thumbnails, and everything else gets a
						glyph for its format. Tap an object and it opens in the system preview,
						with Apple's own share and done controls left intact.
					</p>
					<p className="mt-4 max-w-md text-base/6 text-pretty text-kumo-subtle">
						Uploads run off the main thread with progress and cancel. Some fixes are
						a config value instead, so KV keys open in a JSON editor with Format and
						Save.
					</p>
				</>
			),
			id: 'handle',
			media: <AppScreenshot screenshot={r2Shot} size="standard" />,
		},
	]

	return (
		<section className="scroll-mt-20 bg-kumo-base" data-od-id="incident-tour" id="features">
			<div className="
				mx-auto w-full max-w-7xl px-5 py-20
				sm:px-8 sm:py-24
			"
			>
				<StickyTour stops={stops} />
			</div>
		</section>
	)
}

function AppScreenshot({
	priority = false,
	screenshot,
	size,
}: {
	priority?: boolean
	screenshot: ScreenshotSpec
	size: 'hero' | 'standard'
}) {
	const widthClass = size === 'hero' ? 'max-w-96' : 'max-w-80'

	return (
		<figure className={`
			mx-auto w-full
			${widthClass}
		`}
		>
			{/* Shadow wrapper stays outside the frame so `filter` cannot defeat
			    the screen clip (see app-shot-shadow / app-shot-screen-clip). */}
			<div className="app-shot-shadow">
				<div className="app-shot-frame">
					<div className="app-shot-screen-clip">
						<img
							alt={screenshot.alt}
							className="app-shot-screen"
							fetchPriority={priority ? 'high' : 'auto'}
							height={SHOT_HEIGHT}
							loading={priority ? 'eager' : 'lazy'}
							src={screenshot.src}
							width={SHOT_WIDTH}
						/>
					</div>
					<img
						alt=""
						aria-hidden="true"
						className="app-shot-bezel"
						draggable={false}
						fetchPriority={priority ? 'high' : 'auto'}
						height="730"
						loading={priority ? 'eager' : 'lazy'}
						src={IPHONE_16_PRO_FRAME}
						width="356"
					/>
				</div>
			</div>
		</figure>
	)
}

function OperatingSystemSurfaces() {
	return (
		<section className="border-y border-kumo-hairline bg-kumo-canvas" data-od-id="os-surfaces">
			<div className="
				mx-auto grid w-full max-w-7xl gap-12 px-5 py-20
				sm:px-8 sm:py-24
				lg:grid-cols-12 lg:gap-x-10
			"
			>
				<Reveal className="lg:col-span-4">
					<h2 className="
						max-w-[14ch] text-4xl/[1] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-5xl/[0.96]
					"
					>
						Some of it happens with the app closed.
					</h2>
					<p className="mt-6 max-w-sm text-base/6 text-pretty text-kumo-subtle">
						An iPhone client that only works while you are looking at it is a
						website with an icon.
					</p>
				</Reveal>

				<Stagger className="lg:col-span-7 lg:col-start-6">
					{osSurfaces.map(({ label, text }) => (
						<StaggerItem
							className="
								grid gap-2 border-t border-kumo-hairline py-6
								last:border-b
								sm:grid-cols-[minmax(0,10rem)_minmax(0,1fr)] sm:gap-8
							"
							key={label}
						>
							<h3 className="text-base font-medium tracking-[-0.012em] text-kumo-strong">{label}</h3>
							<p className="text-sm/6 text-pretty text-kumo-subtle">{text}</p>
						</StaggerItem>
					))}
				</Stagger>
			</div>
		</section>
	)
}

function RelaySection() {
	return (
		<section
			className="scroll-mt-20 bg-kumo-contrast text-kumo-inverse"
			data-od-id="relay-model"
			id="security"
		>
			<div className="
				mx-auto w-full max-w-7xl px-5 py-20
				sm:px-8 sm:py-24
			"
			>
				<Reveal>
					<h2 className="
						max-w-[18ch] text-4xl/[1] font-semibold tracking-tight text-balance
						sm:text-5xl/[0.96]
					"
					>
						One server exists, and this is all of it.
					</h2>
					<p className="mt-6 max-w-xl text-base/6 text-pretty text-kumo-inverse/60">
						Sign in is Cloudflare OAuth with PKCE. The verifier never leaves the
						iPhone, the code exchange runs on the device, and the tokens go into the
						Keychain. One server is involved, because Cloudflare accepts only HTTPS
						redirect URIs and APNs needs something that holds the signing key. That
						is its entire job.
					</p>
				</Reveal>

				<Stagger className="
					mt-14 grid gap-x-10
					sm:grid-cols-2
					lg:grid-cols-3
				"
				>
					{relayFacts.map(({ label, text }) => (
						<StaggerItem className="py-6 rule-on-contrast" key={label}>
							<h3 className="text-base font-medium tracking-[-0.012em]">{label}</h3>
							<p className="mt-2 text-sm/6 text-pretty text-kumo-inverse/60">{text}</p>
						</StaggerItem>
					))}
				</Stagger>
			</div>
		</section>
	)
}

function FinalCallToAction() {
	return (
		<section className="bg-kumo-base" data-od-id="final-call-to-action">
			<div className="
				mx-auto grid w-full max-w-7xl gap-12 px-5 py-20
				sm:px-8 sm:py-24
				lg:grid-cols-12 lg:gap-x-10
			"
			>
				<Reveal className="lg:col-span-6">
					<img alt="" className="size-20 rounded-[18px]" height="80" src={dashAppIconUrl} width="80" />
					<h2 className="
						mt-8 max-w-[16ch] text-4xl/[1] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-5xl/[0.96]
					"
					>
						Check it before you connect it.
					</h2>
				</Reveal>

				<Reveal className="lg:col-span-5 lg:col-start-8 lg:pt-4" delay={0.08}>
					<p className="max-w-md text-base/6 text-pretty text-kumo-subtle">
						Claims about custody are worth what you can verify. Explore the demo
						opens a read-only sample account inside the app, with no sign-in and no
						token of any kind. Mutating controls stay locked, and the demo backend
						refuses writes even if something gets past the interface.
					</p>
					<p className="mt-4 max-w-md text-base/6 text-pretty text-kumo-subtle">
						Or read the repository first. The app, the Cloudflare API package, and
						the relay Worker are all in it, including the storage bindings that are
						not there.
					</p>
					<div className="mt-8">
						<LinkButton
							className="pressable"
							href={PRIMARY_CTA_HREF}
							size="lg"
							variant="primary"
							external
						>
							{PRIMARY_CTA_LABEL}
						</LinkButton>
					</div>
					{/* `kumo-inactive` is the disabled-control token and lands at 1.48:1
					    here. Fine print is still text, so it takes a text token. */}
					<p className="mt-6 text-sm/6 text-pretty text-kumo-subtle">
						iPhone, iOS 17 and later, portrait. English and Simplified Chinese.
					</p>
				</Reveal>
			</div>
		</section>
	)
}
