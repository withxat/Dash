import { ApiError } from '@cloudfx/api'

/** True when the error is a Cloudflare permission failure (missing scope). */
export function isForbidden(error: unknown): boolean {
	return error instanceof ApiError && (error.status === 403 || error.status === 401)
}
