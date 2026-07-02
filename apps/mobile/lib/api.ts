import { CloudflareClient } from '@cloudfx/api'
import { QueryClient } from '@tanstack/react-query'

import { CLOUDFLARE_CLIENT_ID } from './config'
import { secureTokenStore } from './storage'

export const queryClient = new QueryClient({
	defaultOptions: {
		queries: {
			refetchOnWindowFocus: false,
			retry: 1,
			staleTime: 60_000,
		},
	},
})

export const cloudflareClient = new CloudflareClient({
	clientId: CLOUDFLARE_CLIENT_ID,
	tokenStore: secureTokenStore,
})
