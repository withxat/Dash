import type { SolarIconComponent } from './solar-icons'

import { Badge } from '@cloudflare/kumo/components/badge'
import { LinkButton } from '@cloudflare/kumo/components/button'
import { Link } from '@cloudflare/kumo/components/link'

import { dashAppIconUrl } from './brand-assets'
import { SiteShell } from './site-shell'
import {
	SolarChartIcon,
	SolarCloudIcon,
	SolarCloudStorageIcon,
	SolarCodeIcon,
	SolarDatabaseIcon,
	SolarGlobalIcon,
	SolarLockIcon,
} from './solar-icons'

// GitHub is the only public release destination until the App Store listing is
// actually live. Keep the label and destination aligned, and never publish a
// placeholder App Store URL.
const PRIMARY_CTA_HREF = 'https://github.com/withxat/Dash'
const PRIMARY_CTA_LABEL = 'Follow development on GitHub'
const RELEASE_STATUS = 'App Store release in progress'

interface Feature {
	description: string
	icon: SolarIconComponent
	name: string
	number: string
}

interface ScreenshotSpec {
	alt: string
	description: string
	label: string
	src?: string
}

const features: Feature[] = [
	{
		description: 'DNS, analytics, and zone settings.',
		icon: SolarGlobalIcon,
		name: 'Zones',
		number: '01',
	},
	{
		description: 'Deployments, routes, and traffic.',
		icon: SolarCodeIcon,
		name: 'Workers',
		number: '02',
	},
	{
		description: 'Projects, builds, and live activity.',
		icon: SolarCloudIcon,
		name: 'Pages',
		number: '03',
	},
	{
		description: 'Browse, preview, upload, and share.',
		icon: SolarCloudStorageIcon,
		name: 'R2',
		number: '04',
	},
	{
		description: 'Inspect namespaces and key-value data.',
		icon: SolarDatabaseIcon,
		name: 'KV',
		number: '05',
	},
]

const homeScreenshot: ScreenshotSpec = {
	alt: 'Dash Home screen',
	description: 'The compact launch point for daily Cloudflare work.',
	label: 'Home',
}

const resourcesScreenshot: ScreenshotSpec = {
	alt: 'Dash Resources screen',
	description: 'Zones, Workers, Pages, R2, and KV in one phone-first stack.',
	label: 'Resources',
}

const watchtowerScreenshot: ScreenshotSpec = {
	alt: 'Dash Watchtower screen',
	description: 'Account health folded into signals that lead somewhere useful.',
	label: 'Watchtower',
}

export function LandingPage() {
	return (
		<SiteShell mainId="main-content">
			<main id="main-content">
				<Hero />
				<CapabilityIndex />
				<AppGallery />
				<NativeSection />
				<SecuritySection />
				<FinalCallToAction />
			</main>
		</SiteShell>
	)
}

function Hero() {
	return (
		<section className="overflow-hidden bg-kumo-base" data-od-id="dash-hero">
			<div className="
				mx-auto w-full max-w-7xl px-5 py-16
				sm:px-8 sm:py-24
			"
			>
				<div className="
					grid gap-12
					lg:grid-cols-12 lg:items-end lg:gap-x-8
				"
				>
					<div className="lg:col-span-8">
						<div className="hero-enter hero-enter-1">
							<Badge variant="orange">Built for iPhone</Badge>
						</div>
						<h1 className="mt-6 max-w-[11ch] hero-enter text-[clamp(3.5rem,7.5vw,6.5rem)]/[0.9] font-semibold tracking-[-0.04em] text-balance text-kumo-strong hero-enter-2">
							Run Cloudflare beyond the desk.
						</h1>
					</div>

					<div className="
						hero-enter hero-enter-3
						lg:col-span-4
					"
					>
						<img
							alt=""
							className="size-16 rounded-[14px]"
							height="64"
							src={dashAppIconUrl}
							width="64"
						/>
						<p className="mt-6 max-w-md text-base/6 text-pretty text-kumo-subtle">
							Dash brings the Cloudflare work that cannot wait into one focused,
							native iPhone app. Sign in with OAuth, then go straight to the
							resource that needs you.
						</p>
						<div className="mt-8 flex flex-col items-start gap-2">
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
								className="flex min-h-11 items-center rounded-md px-1 text-sm font-medium"
								href="#app"
								variant="plain"
							>
								Preview the app
							</Link>
						</div>
						<p className="mt-4 max-w-md text-sm/5 text-pretty text-kumo-subtle">
							{RELEASE_STATUS}
							. GitHub is the current source for code and updates.
						</p>
						<p className="mt-2 text-sm text-kumo-inactive">
							OAuth + PKCE. Tokens stay in the Keychain.
						</p>
					</div>
				</div>
			</div>

			<ProductField />
		</section>
	)
}

function ProductField() {
	return (
		<div className="hero-enter bg-kumo-contrast text-kumo-inverse hero-enter-3">
			<div className="
				mx-auto grid w-full max-w-7xl gap-12 px-5 py-16
				sm:px-8 sm:py-20
				lg:grid-cols-12 lg:items-center lg:gap-x-10
			"
			>
				<div className="lg:col-span-3">
					<p className="text-sm font-medium text-kumo-inverse/60">App preview</p>
					<h2 className="mt-4 max-w-[9ch] text-3xl/[1] font-semibold tracking-[-0.022em] text-balance">
						A real product preview is coming.
					</h2>
					<p className="mt-5 max-w-60 text-sm/6 text-pretty text-kumo-inverse/60">
						We will publish real device captures from the shipping app, never a
						reconstructed dashboard or fictional product shot.
					</p>
				</div>

				<div className="
					flex items-end justify-center overflow-hidden
					lg:col-span-6 lg:px-6
				"
				>
					<AppScreenshot screenshot={homeScreenshot} size="hero" />
				</div>

				<div className="lg:col-span-3">
					<p className="text-sm font-medium text-kumo-inverse/70">Release preview</p>
					<p className="mt-3 max-w-60 text-sm/6 text-pretty text-kumo-inverse/55">
						Real Home, Resources, and Watchtower captures will appear here before
						the App Store release.
					</p>
					<p className="mt-5 text-sm text-kumo-inverse/70">
						Native iPhone app · iOS 17+
					</p>
				</div>
			</div>
		</div>
	)
}

function CapabilityIndex() {
	return (
		<section className="scroll-mt-20 border-b border-kumo-hairline bg-kumo-base" data-od-id="capability-index" id="features">
			<div className="
				mx-auto grid w-full max-w-7xl gap-10 px-5 py-20
				sm:px-8 sm:py-24
				lg:grid-cols-12 lg:gap-x-6
			"
			>
				<div className="lg:col-span-3">
					<SectionMarker label="Capabilities" number="01" />
				</div>
				<div className="lg:col-span-9">
					<div className="
						grid gap-8 border-b border-kumo-line pb-10
						sm:grid-cols-[minmax(0,1.2fr)_minmax(16rem,0.8fr)] sm:items-end
					"
					>
						<h2 className="
							max-w-[12ch] text-4xl/[1] font-semibold tracking-tight text-balance text-kumo-strong
							sm:text-5xl/[0.96]
						"
						>
							Five Cloudflare surfaces. No filler.
						</h2>
						<p className="
							max-w-md text-sm/6 text-pretty text-kumo-subtle
							sm:justify-self-end
						"
						>
							Each destination is a native workflow, not a thin web wrapper. The
							actual screenshots can carry the visual detail.
						</p>
					</div>

					<ol className="divide-y divide-kumo-hairline border-b border-kumo-hairline">
						{features.map(({ description, icon: IconComponent, name, number }) => (
							<li
								className="
									grid gap-4 py-6
									sm:grid-cols-[3rem_minmax(10rem,0.8fr)_minmax(0,1.2fr)] sm:items-center sm:gap-6
								"
								key={name}
							>
								<span className="text-xs text-kumo-inactive tabular-nums">{number}</span>
								<div className="flex items-center gap-3">
									<span className="flex size-10 shrink-0 items-center justify-center rounded-[10px] bg-kumo-recessed text-kumo-brand">
										<IconComponent size={20} weight="fill" aria-hidden />
									</span>
									<h3 className="text-xl font-medium tracking-[-0.012em] text-kumo-strong">{name}</h3>
								</div>
								<p className="text-sm/5 text-pretty text-kumo-subtle">{description}</p>
							</li>
						))}
					</ol>
				</div>
			</div>
		</section>
	)
}

function AppGallery() {
	return (
		<section className="scroll-mt-20 bg-kumo-canvas" data-od-id="app-gallery" id="app">
			<div className="
				mx-auto w-full max-w-7xl px-5 py-20
				sm:px-8 sm:py-24
			"
			>
				<div className="
					grid gap-10
					lg:grid-cols-12 lg:gap-x-6
				"
				>
					<div className="lg:col-span-3">
						<SectionMarker label="The app" number="02" />
					</div>
					<div className="lg:col-span-9">
						<p className="text-sm font-medium text-kumo-brand">Product tour in progress</p>
						<h2 className="
							mt-4 max-w-[14ch] text-4xl/[1] font-semibold tracking-tight text-balance text-kumo-strong
							sm:text-5xl/[0.96]
						"
						>
							Three places. One compact stack.
						</h2>
						<p className="mt-6 max-w-xl text-base/6 text-pretty text-kumo-subtle">
							Home, Resources, and Watchtower are real shipping surfaces. Their
							labeled frames stay honest until final device captures are ready.
						</p>
					</div>
				</div>

				<div className="
					mt-14 grid items-start gap-12
					sm:grid-cols-2 sm:gap-8
					lg:ml-[25%]
				"
				>
					<AppScreenshot screenshot={resourcesScreenshot} size="standard" />
					<AppScreenshot screenshot={watchtowerScreenshot} size="standard" />
				</div>
			</div>
		</section>
	)
}

function AppScreenshot({ screenshot, size }: { screenshot: ScreenshotSpec, size: 'hero' | 'standard' }) {
	const widthClass = size === 'hero' ? 'max-w-96' : 'max-w-80'

	return (
		<figure className={`
			mx-auto w-full
			${widthClass}
		`}
		>
			<div className="rounded-[2.5rem] bg-kumo-elevated p-2 app-shot-frame">
				{screenshot.src
					? (
							<img
								alt={screenshot.alt}
								className="aspect-9/19.5 w-full rounded-4xl object-cover app-shot-image"
								height="2556"
								loading={size === 'hero' ? 'eager' : 'lazy'}
								src={screenshot.src}
								width="1179"
							/>
						)
					: (
							<div
								className="
									flex aspect-9/19.5 w-full flex-col items-center justify-center rounded-4xl bg-kumo-recessed px-6 text-center
									text-kumo-default ring-1 ring-kumo-line ring-inset
								"
								aria-label={`${screenshot.alt} placeholder`}
								role="img"
							>
								<img alt="" className="size-16" height="64" src={dashAppIconUrl} width="64" />
								<p className="mt-5 text-sm font-medium">
									{screenshot.label}
									{' '}
									capture coming
								</p>
								<p className="mt-2 max-w-44 text-xs/5 text-pretty text-kumo-subtle">
									Real iPhone imagery has not been published yet.
								</p>
							</div>
						)}
			</div>
			{size === 'standard' && (
				<figcaption className="mt-5 border-t border-kumo-hairline pt-4">
					<p className="text-sm font-medium text-kumo-strong">{screenshot.label}</p>
					<p className="mt-1 text-sm/5 text-pretty text-kumo-subtle">{screenshot.description}</p>
				</figcaption>
			)}
		</figure>
	)
}

function NativeSection() {
	return (
		<section className="border-y border-kumo-hairline bg-kumo-base" data-od-id="native-principles">
			<div className="
				mx-auto grid w-full max-w-7xl gap-10 px-5 py-20
				sm:px-8 sm:py-24
				lg:grid-cols-12 lg:gap-x-6
			"
			>
				<div className="lg:col-span-3">
					<SectionMarker label="Native principles" number="03" />
				</div>
				<div className="lg:col-span-9">
					<Badge variant="neutral">Built for iPhone</Badge>
					<h2 className="
						mt-5 max-w-[16ch] text-4xl/[1] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-5xl/[0.96]
					"
					>
						One phone. One stack. No squeezed dashboard.
					</h2>

					<div className="
						mt-14 grid border-y border-kumo-hairline
						lg:grid-cols-3
					"
					>
						<Principle
							description="SwiftUI, system navigation, and one compact portrait canvas per tab."
							icon={SolarGlobalIcon}
							number="01"
							title="Native from the start"
						/>
						<Principle
							description="OAuth tokens stay in the Keychain. The relay never receives Cloudflare credentials."
							icon={SolarLockIcon}
							number="02"
							title="Your account stays yours"
						/>
						<Principle
							description="Watchtower turns account health into concise signals with useful destinations."
							icon={SolarChartIcon}
							number="03"
							title="Operational at a glance"
						/>
					</div>
				</div>
			</div>
		</section>
	)
}

function Principle({
	description,
	icon: IconComponent,
	number,
	title,
}: {
	description: string
	icon: SolarIconComponent
	number: string
	title: string
}) {
	return (
		<div className="
			border-b border-kumo-hairline py-7
			lg:border-r lg:border-b-0 lg:px-6
			lg:first:pl-0
			lg:last:border-r-0 lg:last:pr-0
		"
		>
			<div className="flex items-center justify-between gap-4">
				<span className="text-xs text-kumo-inactive tabular-nums">{number}</span>
				<span className="flex size-10 shrink-0 items-center justify-center rounded-[10px] bg-kumo-recessed text-kumo-brand">
					<IconComponent size={20} aria-hidden />
				</span>
			</div>
			<h3 className="mt-8 max-w-[12ch] text-xl/[1.05] font-medium tracking-[-0.012em] text-balance text-kumo-strong">{title}</h3>
			<p className="mt-4 text-sm/6 text-pretty text-kumo-subtle">{description}</p>
		</div>
	)
}

function SecuritySection() {
	return (
		<section className="scroll-mt-20 bg-kumo-contrast text-kumo-inverse" data-od-id="security-model" id="security">
			<div className="
				mx-auto grid w-full max-w-7xl gap-10 px-5 py-20
				sm:px-8 sm:py-24
				lg:grid-cols-12 lg:gap-x-6
			"
			>
				<div className="lg:col-span-3">
					<SectionMarker label="Security model" number="04" dark />
				</div>
				<div className="lg:col-span-9">
					<h2 className="
						max-w-[14ch] text-4xl/[1] font-semibold tracking-tight text-balance
						sm:text-5xl/[0.96]
					"
					>
						The relay redirects. Your secrets do not.
					</h2>
					<p className="mt-6 max-w-xl text-sm/6 text-pretty text-kumo-inverse/60">
						Cloudflare requires an HTTPS OAuth callback. Dash uses a stateless
						Worker only to return the authorization response to the app.
					</p>

					<dl className="mt-14 divide-y divide-white/15 border-y border-white/15">
						<SecurityFact detail="Keychain only" term="OAuth tokens" />
						<SecurityFact detail="Never relayed" term="PKCE verifier" />
						<SecurityFact detail="Zero" term="Server storage" />
					</dl>
				</div>
			</div>
		</section>
	)
}

function SecurityFact({ detail, term }: { detail: string, term: string }) {
	return (
		<div className="
			grid min-h-24 gap-3 py-5
			sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:gap-8
		"
		>
			<dt className="text-sm text-kumo-inverse/55">{term}</dt>
			<dd className="text-xl font-medium tracking-[-0.012em] tabular-nums">{detail}</dd>
		</div>
	)
}

function FinalCallToAction() {
	return (
		<section className="bg-kumo-base" data-od-id="final-call-to-action">
			<div className="
				mx-auto grid w-full max-w-7xl gap-10 px-5 py-20
				sm:px-8 sm:py-24
				lg:grid-cols-12 lg:items-end lg:gap-x-6
			"
			>
				<div className="lg:col-span-2">
					<img alt="" className="size-20 rounded-[18px]" height="80" src={dashAppIconUrl} width="80" />
				</div>
				<div className="lg:col-span-7">
					<p className="text-sm font-medium text-kumo-brand">Dash for Cloudflare</p>
					<h2 className="
						mt-4 max-w-[12ch] text-4xl/[1] font-semibold tracking-tight text-balance text-kumo-strong
						sm:text-5xl/[0.96]
					"
					>
						Cloudflare, within reach.
					</h2>
					<p className="mt-5 text-sm text-kumo-subtle">
						Built for iPhone. Available as open source.
						{' '}
						{RELEASE_STATUS}
						.
					</p>
				</div>
				<div className="lg:col-span-3 lg:justify-self-end">
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
			</div>
		</section>
	)
}

function SectionMarker({ dark = false, label, number }: { dark?: boolean, label: string, number: string }) {
	return (
		<div className={`
			flex items-center gap-3 text-sm
			${dark ? 'text-kumo-inverse/70' : 'text-kumo-subtle'}
		`}
		>
			<span className={`
				font-medium tabular-nums
				${dark ? 'text-kumo-inverse' : 'text-kumo-brand'}
			`}
			>
				{number}
			</span>
			<p className="font-medium">{label}</p>
		</div>
	)
}
