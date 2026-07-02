import { createContext } from 'react'

export type AuthStatus = 'authenticated' | 'loading' | 'unauthenticated'

export interface AuthContextValue {
	/** Last OAuth error message, if any. */
	error: null | string
	/** True while exchanging the authorization code for tokens. */
	exchanging: boolean
	signIn: () => Promise<void>
	signOut: () => Promise<void>
	status: AuthStatus
}

export const AuthContext = createContext<AuthContextValue | null>(null)
