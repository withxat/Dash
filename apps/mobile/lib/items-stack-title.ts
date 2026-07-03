import type { AppCatalogIcon } from './app-catalog'

import { APP_CATALOG } from './app-catalog'

const EXACT_TITLES: Record<string, string> = {
	'account/index': 'Account',
	'items': 'Items',
	'profile': 'Profile',
	'storage/d1/[uuid]': 'Database',
	'storage/d1/index': 'D1',
	'storage/index': 'Storage',
	'storage/kv/[namespace]': 'Namespace',
	'storage/kv/index': 'KV',
	'storage/queues/[queue]': 'Queue',
	'storage/queues/index': 'Queues',
	'storage/r2/[bucket]': 'Bucket',
	'storage/r2/index': 'R2',
	'storage/secrets/[store]': 'Store',
	'storage/secrets/index': 'Secrets Store',
	'workers/[name]/index': 'Worker',
	'workers/index': 'Workers & Pages',
	'workers/pages/[project]/[deployment]': 'Deployment',
	'workers/pages/[project]/index': 'Pages',
	'zones/[id]/index': 'Zone',
	'zones/index': 'Zones',
}

const LEAF_TITLES: Record<string, string> = {
	'access-apps': 'Access apps',
	'access-rules': 'IP Access Rules',
	'analytics': 'Analytics',
	'builds': 'Builds',
	'cache': 'Cache',
	'deployments': 'Deployments',
	'dns': 'DNS records',
	'domains': 'Custom domains',
	'email-addresses': 'Email addresses',
	'email-routing': 'Email Routing',
	'healthchecks': 'Healthchecks',
	'images': 'Images',
	'lb-pools': 'LB Pools',
	'load-balancers': 'Load Balancers',
	'logs': 'Logs',
	'page-rules': 'Page Rules',
	'registrar': 'Registrar',
	'routes': 'Workers routes',
	'security': 'Security',
	'settings': 'Settings',
	'source': 'Source',
	'ssl': 'SSL/TLS',
	'stream': 'Stream',
	'tunnels': 'Tunnels',
	'turnstile': 'Turnstile',
	'vectorize': 'Vectorize',
	'waf': 'WAF rules',
	'waiting-rooms': 'Waiting Rooms',
}

/** Routes under Items that are not catalog href prefixes. */
const ROUTE_ICON_OVERRIDES: Record<string, AppCatalogIcon> = {
	'storage/kv-entry': 'kv',
	'storage/namespace-edit': 'kv',
	'storage/new-bucket': 'r2',
	'storage/r2-object': 'r2',
	'storage/r2-upload': 'r2',
}

const CATALOG_ROUTE_PREFIXES = APP_CATALOG.flatMap(category => category.items)
	.map(item => ({ icon: item.icon, prefix: String(item.href).replace(/^\//, '') }))
	.sort((a, b) => b.prefix.length - a.prefix.length)

export function itemsStackIcon(routeName: string): AppCatalogIcon | undefined {
	if (routeName === 'items' || routeName === 'profile')
		return undefined

	const override = ROUTE_ICON_OVERRIDES[routeName]
	if (override)
		return override

	const match = CATALOG_ROUTE_PREFIXES.find(({ prefix }) =>
		routeName === prefix || routeName.startsWith(`${prefix}/`))
	return match?.icon
}

export function itemsStackTitle(routeName: string): string {
	const exact = EXACT_TITLES[routeName]
	if (exact)
		return exact

	const tail = routeName.split('/').at(-1) ?? routeName
	return LEAF_TITLES[tail] ?? tail
}
