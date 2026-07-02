import { Redirect } from 'expo-router'

import { useAuth } from '../lib/use-auth'

export default function Index() {
	const { status } = useAuth()
	if (status === 'loading')
		return null
	return status === 'authenticated' ? <Redirect href="/home" /> : <Redirect href="/login" />
}
