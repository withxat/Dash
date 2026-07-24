import privacyPolicy from '@dash/legal/PrivacyPolicy.md?raw'
import termsOfUse from '@dash/legal/TermsOfUse.md?raw'
import { lazy, Suspense } from 'react'

import { LandingPage } from './landing-page'

const LegalPage = lazy(async () => {
	const module = await import('./legal-page')
	return { default: module.LegalPage }
})

export function App() {
	const pathname = window.location.pathname.replace(/\/$/, '') || '/'
	if (pathname === '/privacy') {
		return (
			<Suspense fallback={<LegalPageFallback />}>
				<LegalPage document={privacyPolicy} title="Privacy Policy" />
			</Suspense>
		)
	}
	if (pathname === '/terms') {
		return (
			<Suspense fallback={<LegalPageFallback />}>
				<LegalPage document={termsOfUse} title="Terms of Use" />
			</Suspense>
		)
	}

	return <LandingPage />
}

function LegalPageFallback() {
	return (
		<div className="flex min-h-dvh items-center justify-center bg-kumo-canvas text-sm text-kumo-subtle" role="status">
			Loading document…
		</div>
	)
}
