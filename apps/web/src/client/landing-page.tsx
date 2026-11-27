import { DitheredSunriseCanvas } from './dither-canvas'
import { useLocale } from './i18n'
import { Stagger, StaggerItem } from './motion-primitives'
import { GitHubMarkIcon, SiteShell } from './site-shell'

const PRIMARY_CTA_HREF = 'https://github.com/withxat/Dash'
const RELAY_SOURCE_HREF = 'https://github.com/withxat/Dash/tree/main/apps/web/src/worker'

const SHOT_VERSION = '?v=1'
const SHOT_WIDTH = 1206
const SHOT_HEIGHT = 2622
const IPHONE_16_PRO_FRAME = '/device-frames/iphone-16-pro-desert-titanium.svg?v=2'

interface ScreenshotSpec {
	alt: string
	src: string
}

export function LandingPage() {
	return (
		<SiteShell mainId="main-content">
			<main id="main-content">
				<HeroSection />
				<SurfacesSection />
				<ArchitectureSection />
			</main>
		</SiteShell>
	)
}

function HeroSection() {
	const { locale, t } = useLocale()
	const insightsShot: ScreenshotSpec = {
		alt: t.watchtowerAlt,
		src: `/screens/watchtower.webp${SHOT_VERSION}`,
	}

	return (
		<section
			className="
				mx-auto max-w-[1200px] px-5 pt-6 pb-16
				sm:px-8 sm:pt-10 sm:pb-24
			"
			data-od-id="dash-hero"
		>
			<Stagger
				className="
					grid gap-8
					lg:grid-cols-12 lg:items-end lg:gap-10
				"
				on="load"
			>
				<StaggerItem className="lg:col-span-7">
					<h1
						className={
							locale === 'zh'
								? 'text-[clamp(2.85rem,6vw,5rem)]/[1.14] font-medium tracking-tight text-dash-ink'
								: 'text-[clamp(3rem,6.4vw,5.35rem)]/[0.96] font-medium tracking-[-0.045em] text-dash-ink'
						}
					>
						{t.heroHeadingDark}
						<br />
						<span className="text-dash-faint">{t.heroHeadingFaint}</span>
					</h1>
				</StaggerItem>

				<StaggerItem className="lg:col-span-5 lg:pb-1.5">
					<p className="
						max-w-[36ch] text-[16px]/[1.6] text-pretty text-dash-muted
						sm:text-[17px]/[1.55]
					"
					>
						{t.heroSubtitle}
					</p>
					<div className="mt-6 flex flex-wrap items-center gap-x-5 gap-y-3">
						<a
							className="
								inline-flex h-10 pressable items-center gap-2 rounded-full bg-dash-ink px-5 text-[13px] font-medium
								text-white transition-colors
								hover:bg-[#272624]
								focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-dash-accent-deep
							"
							href={PRIMARY_CTA_HREF}
							rel="noopener noreferrer"
							target="_blank"
						>
							<GitHubMarkIcon className="size-3.5" />
							<span>{t.heroCta}</span>
						</a>
						<span className="text-[13px] text-dash-faint">
							{t.heroMeta}
							{' · '}
							{t.heroBy}
							{' '}
							<a
								className="
									text-dash-ink underline decoration-black/20 underline-offset-3 transition-colors
									hover:decoration-dash-ink
								"
								href="https://xat.sh"
								rel="author me noopener noreferrer"
								target="_blank"
							>
								Xat
							</a>
						</span>
					</div>
				</StaggerItem>
			</Stagger>

			<div className="
				relative mt-10 overflow-hidden rounded-[28px] bg-dash-gallery px-6 py-12
				sm:mt-12 sm:px-12 sm:py-14
				lg:py-16
			"
			>
				<DitheredSunriseCanvas className="pointer-events-none absolute inset-0 size-full" />

				<div className="
					relative z-10 grid items-center gap-10
					lg:grid-cols-12 lg:gap-8
				"
				>
					<div className="
						hidden flex-col items-end text-right
						lg:col-span-4 lg:flex lg:self-start lg:pt-24
					"
					>
						<div className="flex items-center gap-4">
							<span className="font-mono text-[10px] tracking-[0.12em] text-dash-faint uppercase">
								{t.calloutLeftLabel}
							</span>
							<span aria-hidden="true" className="h-px w-12 bg-black/15" />
						</div>
						<p className="mt-2 max-w-[22ch] text-[13px]/[1.55] text-pretty text-dash-muted">
							{t.calloutLeftBody}
						</p>
					</div>

					<div className="
						mx-auto w-[256px]
						sm:w-[292px]
						lg:col-span-4 lg:w-[304px]
					"
					>
						<AppScreenshot screenshot={insightsShot} priority />
					</div>

					<div className="
						hidden flex-col items-start text-left
						lg:col-span-4 lg:flex lg:self-end lg:pb-16
					"
					>
						<div className="flex items-center gap-4">
							<span aria-hidden="true" className="h-px w-12 bg-black/15" />
							<span className="font-mono text-[10px] tracking-[0.12em] text-dash-faint uppercase">
								{t.calloutRightLabel}
							</span>
						</div>
						<p className="mt-2 max-w-[22ch] text-[13px]/[1.55] text-pretty text-dash-muted">
							{t.calloutRightBody}
						</p>
					</div>
				</div>
			</div>
		</section>
	)
}

function SurfacesSection() {
	const { locale, t } = useLocale()
	return (
		<section
			className="
				mx-auto max-w-[1200px] px-5 py-16
				sm:px-8 sm:py-24
			"
			id="surfaces"
		>
			<div className="max-w-3xl">
				<h2 className="text-[clamp(1.85rem,3.6vw,2.85rem)]/[1.14] font-medium tracking-[-0.03em] text-balance text-dash-ink">
					{t.surfacesHeadingDark}
					{locale === 'en' ? ' ' : ''}
					<span className="text-dash-faint">{t.surfacesHeadingFaint}</span>
				</h2>
			</div>

			<div className="
				mt-14 grid gap-12
				md:grid-cols-3 md:gap-8
				lg:gap-10
			"
			>
				{t.surfaces.map(surface => (
					<article className="group flex flex-col" key={surface.index}>
						<div className="
							flex justify-center rounded-[24px] bg-dash-gallery px-8 py-10
							sm:px-9 sm:py-12
						"
						>
							<div className="
								w-[220px] transition-transform duration-500 ease-[cubic-bezier(0.16,1,0.3,1)]
								group-hover:-translate-y-1.5
								md:w-full md:max-w-[234px]
							"
							>
								<AppScreenshot
									screenshot={{ alt: surface.alt, src: surface.src }}
									softShadow
								/>
							</div>
						</div>
						<div className="mt-6">
							<span className="font-mono text-[11px] text-dash-faint">
								{surface.index}
							</span>
							<h3 className="mt-2 text-[17px]/[1.3] font-medium tracking-[-0.02em] text-dash-ink">
								{surface.title}
							</h3>
							<p className="mt-1.5 text-[14px]/[1.6] text-pretty text-dash-muted">
								{surface.description}
							</p>
						</div>
					</article>
				))}
			</div>
		</section>
	)
}

function ArchitectureSection() {
	const { locale, t } = useLocale()
	return (
		<section
			className="
				mx-auto max-w-[1200px] px-5 pt-8 pb-12
				sm:px-8 sm:pt-12 sm:pb-16
			"
			id="architecture"
		>
			<div className="
				border-t border-black/8 pt-16
				sm:pt-24
			"
			>
				<h2 className="max-w-4xl text-[clamp(1.85rem,3.6vw,2.85rem)]/[1.14] font-medium tracking-[-0.03em] text-balance text-dash-ink">
					{t.archHeadingDark}
					{locale === 'en' ? ' ' : ''}
					<span className="text-dash-faint">{t.archHeadingFaint}</span>
				</h2>

				<dl className="mt-14 border-t border-black/10">
					<div className="
						grid gap-2 border-b border-black/10 py-6
						md:grid-cols-12 md:gap-8
					"
					>
						<dt className="
							text-[14px] font-medium text-dash-ink
							md:col-span-4
						"
						>
							{t.archDirectLabel}
						</dt>
						<dd className="
							text-[14px]/[1.7] text-pretty text-dash-muted
							md:col-span-8
						"
						>
							{t.archDirectBefore}
							{' '}
							<code className="font-mono text-[13px] text-dash-ink">api.cloudflare.com</code>
							{locale === 'zh' ? '。' : '.'}
						</dd>
					</div>

					<div className="
						grid gap-2 border-b border-black/10 py-6
						md:grid-cols-12 md:gap-8
					"
					>
						<dt className="
							text-[14px] font-medium text-dash-ink
							md:col-span-4
						"
						>
							{t.archRelayLabel}
						</dt>
						<dd className="
							text-[14px]/[1.7] text-pretty text-dash-muted
							md:col-span-8
						"
						>
							<code className="font-mono text-[13px] text-dash-ink">dash.xat.sh</code>
							{' '}
							{t.archRelayAfter}
							{' '}
							<a
								className="
									inline-flex items-center gap-0.5 font-medium text-dash-ink underline decoration-black/25 underline-offset-4 transition-colors
									hover:decoration-dash-ink
								"
								href={RELAY_SOURCE_HREF}
								rel="noopener noreferrer"
								target="_blank"
							>
								<span>{t.archRelaySource}</span>
								<span aria-hidden="true" className="text-[11px]">↗</span>
							</a>
						</dd>
					</div>

					<div className="
						grid gap-2 border-b border-black/10 py-6
						md:grid-cols-12 md:gap-8
					"
					>
						<dt className="
							text-[14px] font-medium text-dash-ink
							md:col-span-4
						"
						>
							{t.archLocalLabel}
						</dt>
						<dd className="
							text-[14px]/[1.7] text-pretty text-dash-muted
							md:col-span-8
						"
						>
							{t.archLocalBody}
						</dd>
					</div>

					<div className="
						grid gap-2 border-b border-black/10 py-6
						md:grid-cols-12 md:gap-8
					"
					>
						<dt className="
							text-[14px] font-medium text-dash-ink
							md:col-span-4
						"
						>
							{t.archNativeLabel}
						</dt>
						<dd className="
							text-[14px]/[1.7] text-pretty text-dash-muted
							md:col-span-8
						"
						>
							{t.archNativeBody}
						</dd>
					</div>
				</dl>
			</div>
		</section>
	)
}

function AppScreenshot({
	priority = false,
	screenshot,
	softShadow = false,
}: {
	priority?: boolean
	screenshot: ScreenshotSpec
	softShadow?: boolean
}) {
	return (
		<div className={softShadow ? 'app-shot-shadow-soft' : 'app-shot-shadow'}>
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
					decoding="async"
					src={IPHONE_16_PRO_FRAME}
				/>
			</div>
		</div>
	)
}
