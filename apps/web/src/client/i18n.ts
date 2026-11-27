import { createContext, use } from 'react'

export type Locale = 'en' | 'zh'

export interface Copy {
	archDirectBefore: string
	archDirectLabel: string
	archHeadingDark: string
	archHeadingFaint: string
	archLocalBody: string
	archLocalLabel: string
	archNativeBody: string
	archNativeLabel: string
	archRelayAfter: string
	archRelayLabel: string
	archRelaySource: string
	calloutLeftBody: string
	calloutLeftLabel: string
	calloutRightBody: string
	calloutRightLabel: string
	footerBlurbAfter: string
	footerBlurbBefore: string
	footerColElsewhere: string
	footerColLegal: string
	footerColProduct: string
	footerMeta: string
	heroBy: string
	heroCta: string
	heroHeadingDark: string
	heroHeadingFaint: string
	heroMeta: string
	heroSubtitle: string
	legalBack: string
	legalEnglishNote: string
	legalLoading: string
	legalPrivacyTitle: string
	legalTermsTitle: string
	navArchitecture: string
	navPrivacy: string
	navSurfaces: string
	pageTitle: string
	skipToContent: string
	surfaces: readonly {
		alt: string
		description: string
		index: string
		src: string
		title: string
	}[]
	surfacesHeadingDark: string
	surfacesHeadingFaint: string
	watchtowerAlt: string
}

const SHOT_VERSION = '?v=1'

export const COPY: Record<Locale, Copy> = {
	en: {
		archDirectBefore: 'OAuth 2.0 PKCE tokens stay in Keychain. Requests go straight to',
		archDirectLabel: 'Direct API',
		archHeadingDark: 'Tokens stay in Keychain.',
		archHeadingFaint: 'Requests go straight to Cloudflare.',
		archLocalBody:
			'Metadata caches clear on sign-out. Worker logs and D1 rows never touch disk. No analytics SDKs.',
		archLocalLabel: 'Local & Ephemeral',
		archNativeBody:
			'Swift 6 & SwiftUI. Files mount, Share Extension, Widgets, Safari handoff, and Face ID lock.',
		archNativeLabel: 'Native iOS',
		archRelayAfter: 'only forwards OAuth callbacks and caches public RDAP lookups. Zero storage, zero logs.',
		archRelayLabel: 'Stateless Relay',
		archRelaySource: 'Source',
		calloutLeftBody: 'Dithered charts, hold to scrub.',
		calloutLeftLabel: 'Insights',
		calloutRightBody: 'One stack, plus Demo mode.',
		calloutRightLabel: 'iPhone Only',
		footerBlurbAfter: '. Unofficial.',
		footerBlurbBefore: 'Open-source Cloudflare client for iPhone, by',
		footerColElsewhere: 'Elsewhere',
		footerColLegal: 'Legal',
		footerColProduct: 'Product',
		footerMeta: 'iOS 17+ · Swift 6 · MIT',
		heroBy: 'By',
		heroCta: 'View on GitHub',
		heroHeadingDark: 'Cloudflare,',
		heroHeadingFaint: 'in your hand.',
		heroMeta: 'iOS 17+ · MIT',
		heroSubtitle: 'A native iPhone client for Cloudflare.',
		legalBack: 'Overview',
		legalEnglishNote: '',
		legalLoading: 'Loading document…',
		legalPrivacyTitle: 'Privacy Policy',
		legalTermsTitle: 'Terms of Use',
		navArchitecture: 'Architecture',
		navPrivacy: 'Privacy',
		navSurfaces: 'Surfaces',
		pageTitle: 'Dash for Cloudflare · Native iPhone Client',
		skipToContent: 'Skip to content',
		surfaces: [
			{
				alt: 'A domain open in Dash showing nameservers, DNS, and quick actions',
				description: 'DNS with undo, WAF, rules, cache, and Registrar.',
				index: '01',
				src: `/screens/zone.webp${SHOT_VERSION}`,
				title: 'Domains',
			},
			{
				alt: 'A Pages project in Dash showing dithered build outcomes and deployment history',
				description: 'Deployments, live logs, rollbacks, and Live Activities.',
				index: '02',
				src: `/screens/pages.webp${SHOT_VERSION}`,
				title: 'Workers & Pages',
			},
			{
				alt: 'An R2 bucket open in Dash showing virtual folders and file-type icons',
				description: 'R2 with iOS Files, KV, plus opt-in D1 and Tunnels.',
				index: '03',
				src: `/screens/r2.webp${SHOT_VERSION}`,
				title: 'Storage',
			},
		],
		surfacesHeadingDark: 'Domains, deploys, storage.',
		surfacesHeadingFaint: 'Built for iPhone.',
		watchtowerAlt:
			'Dash Insights on iPhone showing dithered Web Traffic, CPU Time, and Worker Invocations charts',
	},
	zh: {
		archDirectBefore: 'OAuth 2.0 PKCE 令牌仅存系统钥匙串，所有请求直连',
		archDirectLabel: 'API 直连',
		archHeadingDark: '令牌留在钥匙串，',
		archHeadingFaint: '请求直连 Cloudflare。',
		archLocalBody: '退出登录即清空缓存。Worker 日志与 D1 查询结果永不落盘，无任何统计 SDK。',
		archLocalLabel: '本地与无痕',
		archNativeBody: 'Swift 6 与 SwiftUI 构建。支持文件挂载、分享扩展、小组件、Safari 跳转与面容 ID 锁。',
		archNativeLabel: '原生集成',
		archRelayAfter: '仅转发 OAuth 回调并缓存公开 RDAP 查询。无持久化存储，无请求日志。',
		archRelayLabel: '无状态中继',
		archRelaySource: '查看源码',
		calloutLeftBody: '抖动图表，长按读数。',
		calloutLeftLabel: '数据洞察',
		calloutRightBody: '单栈导航，内置离线演示。',
		calloutRightLabel: '专为 iPhone',
		footerBlurbAfter: ' 制作，非官方项目。',
		footerBlurbBefore: '开源 iPhone Cloudflare 客户端，由',
		footerColElsewhere: '作者',
		footerColLegal: '条款',
		footerColProduct: '产品',
		footerMeta: 'iOS 17+ · Swift 6 · MIT',
		heroBy: '作者',
		heroCta: '在 GitHub 查看',
		heroHeadingDark: 'Cloudflare，',
		heroHeadingFaint: '握在掌心。',
		heroMeta: 'iOS 17+ · MIT',
		heroSubtitle: '为 iPhone 打造的原生 Cloudflare 客户端。',
		legalBack: '返回首页',
		legalEnglishNote: '法律文本以英文原版为准。',
		legalLoading: '正在加载文档…',
		legalPrivacyTitle: '隐私政策',
		legalTermsTitle: '使用条款',
		navArchitecture: '架构',
		navPrivacy: '隐私',
		navSurfaces: '功能',
		pageTitle: 'Dash for Cloudflare · 原生 iPhone 客户端',
		skipToContent: '跳至正文',
		surfaces: [
			{
				alt: 'Dash 域名详情页，展示名称服务器、DNS 与快捷操作',
				description: '支持撤销的 DNS、WAF、规则开关、缓存与注册商。',
				index: '01',
				src: `/screens/zone.webp${SHOT_VERSION}`,
				title: '域名与安全',
			},
			{
				alt: 'Dash Pages 项目页，展示抖动构建统计与部署记录',
				description: '版本切换、实时日志、回滚与锁屏实时活动。',
				index: '02',
				src: `/screens/pages.webp${SHOT_VERSION}`,
				title: 'Workers 与 Pages',
			},
			{
				alt: 'Dash R2 存储桶浏览页，展示虚拟文件夹与文件图标',
				description: '接入 iOS 文件的 R2、KV，以及可选的 D1 与 Tunnels。',
				index: '03',
				src: `/screens/r2.webp${SHOT_VERSION}`,
				title: '存储与扩展',
			},
		],
		surfacesHeadingDark: '域名、部署与存储。',
		surfacesHeadingFaint: '原生 iPhone 体验。',
		watchtowerAlt: 'Dash 数据洞察界面，展示抖动风格的流量、CPU 时间与 Worker 调用图表',
	},
}

export const LOCALE_STORAGE_KEY = 'dash.web.locale'

export function detectInitialLocale(): Locale {
	if (typeof window === 'undefined') {
		return 'en'
	}

	const param = new URLSearchParams(window.location.search).get('lang')?.toLowerCase()
	if (param === 'zh' || param === 'zh-cn' || param === 'zh-hans') {
		return 'zh'
	}
	if (param === 'en') {
		return 'en'
	}

	try {
		const saved = window.localStorage.getItem(LOCALE_STORAGE_KEY)
		if (saved === 'en' || saved === 'zh') {
			return saved
		}
	}
	catch {
		// Ignore storage access errors in private browsing.
	}

	const preferred = window.navigator.languages?.[0] ?? window.navigator.language ?? 'en'
	return preferred.toLowerCase().startsWith('zh') ? 'zh' : 'en'
}

export interface LocaleContextValue {
	locale: Locale
	t: Copy
	toggleLocale: () => void
}

export const LocaleContext = createContext<LocaleContextValue | null>(null)

export function useLocale(): LocaleContextValue {
	const value = use(LocaleContext)
	if (!value) {
		throw new Error('useLocale must be used inside LocaleContext')
	}
	return value
}
