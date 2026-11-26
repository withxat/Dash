// Hands a Cloudflare dashboard link over to Dash.
//
// iOS gives an https link to an app only through Universal Links, and those
// need a file on the link's own domain — so a dash.cloudflare.com link always
// opens Safari. This script is the hand-off from there: when the page Safari
// just loaded names something Dash has a screen for, it navigates to
// `dash://open?url=<that page>`, and Safari asks whether to open Dash.
//
// It runs once per page load, at document start, in the top frame. Moving
// around inside the dashboard afterwards is a client-side route change and
// never re-runs it: someone already browsing the dashboard chose the web.
//
// `dashboardResource` mirrors `CloudflareDashboardLink` in
// packages/cloudflare-api — the Swift parser is the authority, because it is
// what Dash runs on the URL this script sends. The two are held together by
// one fixture list (Tests/CloudflareAPITests/Fixtures/dashboard-links.json)
// that both test suites read: a link this script hands over but Dash cannot
// place would open the app onto nothing.

/**
 * The part of a dashboard URL that names a resource Dash can open, with the
 * account segment dropped, or null when it names none.
 */
function dashboardResource(href) {
	let url
	try {
		url = new URL(href)
	}
	catch {
		return null
	}
	if (url.protocol !== 'https:' && url.protocol !== 'http:')
		return null
	if (url.hostname !== 'dash.cloudflare.com')
		return null

	// `?to=` wins when present: it is Cloudflare's own deep-link form, where
	// the URL's path is only the root the dashboard bounces from.
	const redirects = url.searchParams.getAll('to')
	if (redirects.length > 1)
		return null
	let path
	try {
		path = redirects.length === 1 ? redirects[0] : decodeURIComponent(url.pathname)
	}
	catch {
		return null
	}

	const [account, ...segments] = path.split('/').filter(Boolean)
	if (account === undefined)
		return null
	// `:account` is the placeholder for "whichever account the reader picks".
	if (account !== ':account' && !/^[0-9a-f]{32}$/i.test(account))
		return null

	const isName = value => value.length > 0 && !value.startsWith(':')
	const isIdentifier = value => /^[0-9a-f-]{8,}$/i.test(value)
	const isDomainName = (value) => {
		if (value.length === 0 || value.length > 253 || value.startsWith(':'))
			return false
		const labels = value.toLowerCase().split('.')
		if (labels.length < 2)
			return false
		for (const label of labels) {
			if (label.length === 0 || label.length > 63)
				return false
			if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))
				return false
		}
		const tld = labels[labels.length - 1]
		return /^[a-z]{2,}$/.test(tld) || /^xn--[a-z0-9-]{2,}$/.test(tld)
	}

	// pages/view/<project>[/<deployment-id> | /domains | /<any other tab>]
	if (segments.length >= 3 && segments[0] === 'pages' && segments[1] === 'view') {
		const project = segments[2]
		if (!isName(project))
			return null
		const tail = segments[3]
		if (tail === 'domains')
			return `pages/${project}/domains`
		if (tail !== undefined && isIdentifier(tail))
			return `pages/${project}/${tail}`
		return `pages/${project}`
	}

	// workers/services/view/<worker>[/<environment>[/builds/<build-id> | /<tab>]]
	if (
		segments.length >= 4
		&& segments[0] === 'workers'
		&& segments[1] === 'services'
		&& segments[2] === 'view'
	) {
		const worker = segments[3]
		if (!isName(worker))
			return null
		if (segments.length >= 7 && segments[5] === 'builds' && isIdentifier(segments[6]))
			return `workers/${worker}/builds/${segments[6]}`
		return `workers/${worker}`
	}

	// workers/kv/namespaces/<namespace-id>[/...]
	if (
		segments.length >= 4
		&& segments[0] === 'workers'
		&& segments[1] === 'kv'
		&& segments[2] === 'namespaces'
		&& isIdentifier(segments[3])
	) {
		return `kv/${segments[3]}`
	}

	// r2/default/buckets/<bucket>[/settings | /<tab>]
	if (
		segments.length >= 4
		&& segments[0] === 'r2'
		&& segments[1] === 'default'
		&& segments[2] === 'buckets'
		&& isName(segments[3])
	) {
		const bucket = segments[3]
		if (segments[4] === 'settings')
			return `r2/${bucket}/settings`
		return `r2/${bucket}`
	}

	// zero-trust/networks/tunnels[/cfd_tunnel/<tunnel-id>[/...] | /<tunnel-id>[/...]]
	// zero-trust/networks/connectors/cloudflare-tunnels[/cfd_tunnel/<tunnel-id>[/...] | /<tunnel-id>[/...]]
	const tunnelTail
		= segments.length >= 3
			&& segments[0] === 'zero-trust'
			&& segments[1] === 'networks'
			&& segments[2] === 'tunnels'
			? segments.slice(3)
			: segments.length >= 4
				&& segments[0] === 'zero-trust'
				&& segments[1] === 'networks'
				&& segments[2] === 'connectors'
				&& segments[3] === 'cloudflare-tunnels'
				? segments.slice(4)
				: null
	if (tunnelTail !== null) {
		if (tunnelTail.length === 0)
			return 'tunnels'
		if (tunnelTail[0] === 'cfd_tunnel') {
			return tunnelTail.length >= 2 && isIdentifier(tunnelTail[1])
				? `tunnels/${tunnelTail[1]}`
				: null
		}
		if (isIdentifier(tunnelTail[0]))
			return `tunnels/${tunnelTail[0]}`
		return null
	}

	// audit-log
	if (segments.length === 1 && segments[0] === 'audit-log')
		return 'audit-log'

	// <domain>[/overview | /dns/… | /caching/… | /security[/events | /waf/… | /settings]
	//         | /ssl-tls/… | /network/… | /analytics[/traffic/…] | /email/routing/…]
	if (segments.length >= 1 && isDomainName(segments[0])) {
		const domain = segments[0].toLowerCase()
		const tail = segments.slice(1)
		const section = zoneSection(tail)
		if (section === null)
			return null
		return `zone/${domain}/${section}`
	}

	return null
}

function zoneSection(tail) {
	if (tail.length === 0)
		return 'overview'
	const first = tail[0]
	if (first === 'overview')
		return tail.length === 1 ? 'overview' : null
	if (first === 'dns')
		return 'dns'
	if (first === 'caching')
		return 'cache'
	if (first === 'security') {
		if (tail.length === 1)
			return 'waf'
		if (tail[1] === 'events' || tail[1] === 'waf')
			return 'waf'
		if (tail[1] === 'settings')
			return 'settings'
		return null
	}
	if (first === 'ssl-tls' || first === 'network')
		return 'settings'
	if (first === 'analytics')
		return tail.length === 1 || tail[1] === 'traffic' ? 'analytics' : null
	if (first === 'email')
		return tail.length >= 2 && tail[1] === 'routing' ? 'emailRouting' : null
	return null
}

(() => {
	if (window.top !== window)
		return
	const resource = dashboardResource(location.href)
	if (resource === null)
		return

	// Offer each resource once per tab. Without this a reload — or the
	// dashboard's own hard redirect from `?to=/:account/…` to the account's
	// path, which is the same resource under a different address — would ask
	// again after the reader already said no. Keyed on the resource, not the
	// address, for exactly that second case.
	const key = `dash-handoff:${resource}`
	try {
		if (sessionStorage.getItem(key) !== null)
			return
		sessionStorage.setItem(key, '1')
	}
	catch {
		// Storage can be unavailable (blocked cookies). Asking twice is better
		// than never asking.
	}

	location.href = `dash://open?url=${encodeURIComponent(location.href)}`
})()
