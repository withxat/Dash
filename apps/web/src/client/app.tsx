import type { Locale } from './i18n'

import privacyPolicy from '@dash/legal/PrivacyPolicy.md?raw'
import termsOfUse from '@dash/legal/TermsOfUse.md?raw'
import { lazy, Suspense, useEffect, useState } from 'react'

import { COPY, detectInitialLocale, LOCALE_STORAGE_KEY, LocaleContext, useLocale } from './i18n'
import { LandingPage } from './landing-page'

const LegalPage = lazy(async () => {
	const module = await import('./legal-page')
	return { default: module.LegalPage }
})

export function App() {
	const [locale, setLocale] = useState<Locale>(detectInitialLocale)

	useEffect(() => {
		window.document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en'
		if (window.location.pathname === '/' || window.location.pathname === '') {
			window.document.title = COPY[locale].pageTitle
		}
	}, [locale])

	const toggleLocale = () => {
		setLocale((current) => {
			const next: Locale = current === 'en' ? 'zh' : 'en'
			try {
				window.localStorage.setItem(LOCALE_STORAGE_KEY, next)
			}
			catch {
				// Ignore storage access errors in private browsing.
			}
			return next
		})
	}

	return (
		<LocaleContext value={{ locale, t: COPY[locale], toggleLocale }}>
			<RoutedApp />
		</LocaleContext>
	)
}

function RoutedApp() {
	const { t } = useLocale()
	const pathname = window.location.pathname.replace(/\/$/, '') || '/'
	if (pathname === '/privacy') {
		return (
			<Suspense fallback={<LegalPageFallback />}>
				<LegalPage
					canonicalPath="/privacy"
					description="Privacy Policy for Dash for Cloudflare: OAuth tokens stay in iOS Keychain, API traffic goes directly to Cloudflare, and zero analytics or tracking SDKs are included."
					document={privacyPolicy}
					title={t.legalPrivacyTitle}
				/>
			</Suspense>
		)
	}
	if (pathname === '/terms') {
		return (
			<Suspense fallback={<LegalPageFallback />}>
				<LegalPage
					canonicalPath="/terms"
					description="Terms of Use for Dash for Cloudflare, an unofficial open-source native iPhone client built by Xat."
					document={termsOfUse}
					title={t.legalTermsTitle}
				/>
			</Suspense>
		)
	}

	return <LandingPage />
}

function LegalPageFallback() {
	const { t } = useLocale()
	return (
		<div className="flex min-h-dvh items-center justify-center bg-dash-paper text-sm text-dash-faint" role="status">
			{t.legalLoading}
		</div>
	)
}
