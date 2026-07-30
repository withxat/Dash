import { Badge } from '@cloudflare/kumo/components/badge'
import { LinkButton } from '@cloudflare/kumo/components/button'

import { Stagger, StaggerItem } from './motion-primitives'
import { SiteShell } from './site-shell'

// GitHub is the only public destination that exists today. Keep the label and
// the destination aligned, never publish a placeholder App Store URL, and use
// this one label everywhere the page asks for the same thing.
const PRIMARY_CTA_HREF = 'https://github.com/withxat/Dash'
const PRIMARY_CTA_LABEL = 'Read the source on GitHub'

// Real device captures from the shipping app, stored as WebP at the native
// iPhone 16 Pro display resolution. Bump the query version when a capture is
// replaced.
const SHOT_VERSION = '?v=1'
const SHOT_WIDTH = 1206
const SHOT_HEIGHT = 2622
const IPHONE_16_PRO_FRAME = '/device-frames/iphone-16-pro-desert-titanium.svg?v=2'

interface ScreenshotSpec {
	alt: string
	src: string
}

const zoneShot: ScreenshotSpec = {
	alt: 'A zone open in Dash, with nameservers and quick actions',
	src: `/screens/zone.webp${SHOT_VERSION}`,
}

const watchtowerShot: ScreenshotSpec = {
	alt: 'Watchtower charts for web traffic, CPU time, and Worker invocations',
	src: `/screens/watchtower.webp${SHOT_VERSION}`,
}

const pagesShot: ScreenshotSpec = {
	alt: 'A Pages project with build outcomes and deployment history',
	src: `/screens/pages.webp${SHOT_VERSION}`,
}

/**
 * One screen. One claim. One composition of real captures in device frames.
 * No scroll-through feature tour — the phones carry the product.
 */
export function LandingPage() {
	return (
		<SiteShell mainId="main-content">
			<main id="main-content">
				<section
					className="overflow-x-clip bg-kumo-base"
					data-od-id="dash-hero"
				>
					<div className="
						mx-auto flex w-full max-w-7xl flex-col px-5 pt-12
						sm:px-8 sm:pt-16
					"
					>
						<Stagger
							className="mx-auto max-w-2xl text-center"
							on="load"
						>
							<StaggerItem>
								<Badge variant="orange">Open source. App Store release in progress.</Badge>
							</StaggerItem>
							<StaggerItem>
								<h1 className="mt-6 text-[clamp(2.75rem,6.5vw,4.75rem)]/[0.92] font-semibold tracking-[-0.04em] text-balance text-kumo-strong">
									Cloudflare, on the phone you already carry.
								</h1>
							</StaggerItem>
							<StaggerItem>
								<p className="mx-auto mt-5 max-w-md text-base/6 text-pretty text-kumo-subtle">
									Purge cache, watch traffic, roll back a deploy, browse R2.
									Zones, Workers, Pages, and KV, native and portrait.
								</p>
							</StaggerItem>
							<StaggerItem>
								<div className="mt-8 flex justify-center">
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
							</StaggerItem>
						</Stagger>

						<div className="
							mt-14 pb-16
							sm:mt-16 sm:pb-20
						"
						>
							<DeviceCluster />
						</div>
					</div>
				</section>
			</main>
		</SiteShell>
	)
}

/**
 * Three real captures in the licensed bezel. Desktop fans them at slight
 * angles on the umbrella stage; compact widths lay them upright in a
 * horizontal scroll track instead.
 */
function DeviceCluster() {
	return (
		<div
			aria-label="Dash on iPhone: zone, Watchtower, and Pages screens"
			className="device-cluster"
			role="img"
		>
			{/* Rounded clip only — fill is the animated umbrella gradient, not a flat brand wash. */}
			<div aria-hidden="true" className="device-cluster-stage" />
			<div className="device-cluster-track">
				<div className="device-cluster-phone device-cluster-phone-left">
					<AppScreenshot screenshot={zoneShot} priority />
				</div>
				<div className="device-cluster-phone device-cluster-phone-center">
					<AppScreenshot screenshot={watchtowerShot} priority />
				</div>
				<div className="device-cluster-phone device-cluster-phone-right">
					<AppScreenshot screenshot={pagesShot} priority />
				</div>
			</div>
		</div>
	)
}

function AppScreenshot({
	priority = false,
	screenshot,
}: {
	priority?: boolean
	screenshot: ScreenshotSpec
}) {
	return (
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
	)
}
