import { Redirect, Stack } from 'expo-router'

import { useAuth } from '../../lib/use-auth'

export default function AuthLayout() {
	const { status } = useAuth()
	// Mirror the (app) guard: if the session becomes authenticated while the
	// user is sitting on /login (e.g. right after signIn returns), bounce them
	// into the app. Without this, a successful signIn leaves them on /login
	// until the app is cold-restarted (only then does index.tsx redirect).
	if (status === 'authenticated')
		return <Redirect href="/home" />
	return <Stack screenOptions={{ headerShown: false }} />
}
