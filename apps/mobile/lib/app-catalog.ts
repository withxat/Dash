import type { Href } from 'expo-router'

export type AppCatalogIcon
	= 'access' | 'account' | 'analytics' | 'd1' | 'email' | 'images' | 'kv'
		| 'lb' | 'queues' | 'r2' | 'registrar' | 'secrets' | 'stream'
		| 'tunnels' | 'turnstile' | 'vectorize' | 'workers' | 'zones'

export interface AppCatalogItem {
	description: string
	href: Href
	icon: AppCatalogIcon
	id: string
	title: string
}

export interface AppCatalogCategory {
	id: string
	items: AppCatalogItem[]
	title: string
}

/** Default shortcuts shown on the Home tab. */
export const DEFAULT_HOME_SHORTCUT_IDS = [
	'zones',
	'workers',
	'r2',
	'kv',
] as const

export const APP_CATALOG: AppCatalogCategory[] = [
	{
		id: 'infrastructure',
		items: [
			{
				description: 'Domains, DNS, cache, and zone settings',
				href: '/zones',
				icon: 'zones',
				id: 'zones',
				title: 'Zones',
			},
		],
		title: 'Infrastructure',
	},
	{
		id: 'compute',
		items: [
			{
				description: 'Scripts, routes, deployments, and custom domains',
				href: '/workers',
				icon: 'workers',
				id: 'workers',
				title: 'Workers & Pages',
			},
		],
		title: 'Compute',
	},
	{
		id: 'storage',
		items: [
			{
				description: 'R2 object storage buckets',
				href: '/storage/r2',
				icon: 'r2',
				id: 'r2',
				title: 'R2',
			},
			{
				description: 'Workers KV namespaces',
				href: '/storage/kv',
				icon: 'kv',
				id: 'kv',
				title: 'KV',
			},
			{
				description: 'Serverless SQL databases and console',
				href: '/storage/d1',
				icon: 'd1',
				id: 'd1',
				title: 'D1',
			},
			{
				description: 'Message queues, producers, and consumers',
				href: '/storage/queues',
				icon: 'queues',
				id: 'queues',
				title: 'Queues',
			},
			{
				description: 'Vector indexes for AI search',
				href: '/storage/vectorize',
				icon: 'vectorize',
				id: 'vectorize',
				title: 'Vectorize',
			},
			{
				description: 'Account-level secrets, names only',
				href: '/storage/secrets',
				icon: 'secrets',
				id: 'secrets',
				title: 'Secrets Store',
			},
		],
		title: 'Storage & Data',
	},
	{
		id: 'security',
		items: [
			{
				description: 'CAPTCHA-free widgets and secret rotation',
				href: '/account/turnstile',
				icon: 'turnstile',
				id: 'turnstile',
				title: 'Turnstile',
			},
			{
				description: 'Zero Trust application inventory',
				href: '/account/access-apps',
				icon: 'access',
				id: 'access-apps',
				title: 'Access apps',
			},
		],
		title: 'Security',
	},
	{
		id: 'email-domains',
		items: [
			{
				description: 'Email Routing destination addresses',
				href: '/account/email-addresses',
				icon: 'email',
				id: 'email-addresses',
				title: 'Email addresses',
			},
			{
				description: 'Registered domains and renewals',
				href: '/account/registrar',
				icon: 'registrar',
				id: 'registrar',
				title: 'Registrar',
			},
		],
		title: 'Email & Domains',
	},
	{
		id: 'network',
		items: [
			{
				description: 'Cloudflare Tunnel health and connections',
				href: '/account/tunnels',
				icon: 'tunnels',
				id: 'tunnels',
				title: 'Tunnels',
			},
			{
				description: 'Load balancer origin pools',
				href: '/account/lb-pools',
				icon: 'lb',
				id: 'lb-pools',
				title: 'LB Pools',
			},
		],
		title: 'Network',
	},
	{
		id: 'media',
		items: [
			{
				description: 'Cloudflare Images library',
				href: '/account/images',
				icon: 'images',
				id: 'images',
				title: 'Images',
			},
			{
				description: 'Stream video library',
				href: '/account/stream',
				icon: 'stream',
				id: 'stream',
				title: 'Stream',
			},
		],
		title: 'Media',
	},
	{
		id: 'insights',
		items: [
			{
				description: 'Account and zone traffic charts',
				href: '/account/analytics',
				icon: 'analytics',
				id: 'analytics',
				title: 'Analytics',
			},
		],
		title: 'Insights',
	},
	{
		id: 'account',
		items: [
			{
				description: 'Members, notifications, and audit logs',
				href: '/account',
				icon: 'account',
				id: 'account',
				title: 'Account',
			},
		],
		title: 'Account',
	},
]

const catalogItemsById = new Map(
	APP_CATALOG.flatMap(category => category.items).map(item => [item.id, item]),
)

export function getCatalogItem(id: string): AppCatalogItem | undefined {
	return catalogItemsById.get(id)
}

export function getCatalogItems(ids: readonly string[]): AppCatalogItem[] {
	return ids.flatMap((id) => {
		const item = getCatalogItem(id)
		return item ? [item] : []
	})
}

export function searchCatalogItems(query: string): AppCatalogItem[] {
	const needle = query.trim().toLowerCase()
	if (!needle)
		return APP_CATALOG.flatMap(category => category.items)

	return APP_CATALOG.flatMap(category => category.items).filter(item =>
		item.title.toLowerCase().includes(needle)
		|| item.description.toLowerCase().includes(needle),
	)
}
