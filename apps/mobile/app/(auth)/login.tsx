import { ScrollView, Text, View } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'

import { Button } from '../../components/button'
import { CLOUDFLARE_REDIRECT_URI, isCloudflareConfigured } from '../../lib/config'
import { useAuth } from '../../lib/use-auth'

export default function LoginScreen() {
	const { error, exchanging, signIn, status } = useAuth()

	return (
		<SafeAreaView className="flex-1 bg-canvas" edges={['bottom']}>
			<ScrollView contentContainerClassName="flex-1 items-center justify-center px-6">
				<View className="w-full max-w-md gap-10">
					<View className="items-center gap-3">
						<Text className="text-5xl font-bold text-white">CloudFX</Text>
						<Text className="text-center text-base text-white/60">
							Manage Cloudflare accounts, zones and DNS — right from your phone.
						</Text>
					</View>

					{!isCloudflareConfigured
						? (
								<View className="gap-2 rounded-2xl bg-canvas-soft p-4">
									<Text className="font-semibold text-white">Almost ready</Text>
									<Text className="text-sm leading-5 text-white/70">
										Set
										{' '}
										<Text className="font-mono text-white">EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID</Text>
										{' '}
										to
										your Cloudflare OAuth client id (see the README), then restart the app.
									</Text>
								</View>
							)
						: null}

					<Button
						disabled={!isCloudflareConfigured}
						loading={exchanging || status === 'loading'}
						onPress={signIn}
						size="lg"
					>
						Connect Cloudflare
					</Button>

					{error
						? (
								<Text className="text-center text-sm text-red-400">{error}</Text>
							)
						: null}

					<View className="gap-1 rounded-2xl bg-canvas-soft p-4">
						<Text className="text-xs text-white/50">
							Redirect URI — register this in your Cloudflare OAuth client:
						</Text>
						<Text className="font-mono text-xs text-white/80">{CLOUDFLARE_REDIRECT_URI}</Text>
					</View>
				</View>
			</ScrollView>
		</SafeAreaView>
	)
}
