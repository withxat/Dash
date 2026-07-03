import { ScrollView, Text, View } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'

import { Button, ButtonText } from '../../components/button'
import { Card } from '../../components/card'
import { CLOUDFLARE_REDIRECT_URI, isCloudflareConfigured } from '../../lib/config'
import { useAuth } from '../../lib/use-auth'

export default function LoginScreen() {
	const { error, exchanging, signIn, status } = useAuth()

	return (
		<SafeAreaView className="flex-1 bg-canvas" edges={['bottom']}>
			<ScrollView contentContainerClassName="flex-1 items-center justify-center px-6">
				<View className="w-full max-w-md gap-8">
					<View className="items-center gap-3">
						<View
							className="size-16 items-center justify-center rounded-kumo bg-accent"
							style={{ borderCurve: 'continuous' }}
						>
							<Text className="text-3xl font-bold text-inverse">FX</Text>
						</View>
						<Text className="text-4xl font-bold text-strong">CloudFX</Text>
						<Text className="text-center text-base text-subtle">
							Zones, DNS, cache, security and analytics — your Cloudflare account in your pocket.
						</Text>
					</View>

					{!isCloudflareConfigured
						? (
								<Card>
									<View className="gap-2">
										<Text className="font-semibold text-default">Almost ready</Text>
										<Text className="text-sm leading-5 text-subtle">
											Set
											{' '}
											<Text className="font-mono text-default">EXPO_PUBLIC_CLOUDFLARE_CLIENT_ID</Text>
											{' '}
											and
											{' '}
											<Text className="font-mono text-default">EXPO_PUBLIC_CLOUDFLARE_REDIRECT_URI</Text>
											{' '}
											(the relay Worker URL — see the README), then restart the app.
										</Text>
									</View>
								</Card>
							)
						: null}

					<Button
						disabled={!isCloudflareConfigured}
						loading={exchanging || status === 'loading'}
						onPress={signIn}
						size="lg"
						variant="primary"
					>
						<ButtonText>Connect Cloudflare</ButtonText>
					</Button>

					{error
						? (
								<Text className="text-center text-sm text-danger">{error}</Text>
							)
						: null}

					<Card>
						<View className="gap-1">
							<Text className="text-xs text-subtle">
								Redirect URI — register this in your Cloudflare OAuth client:
							</Text>
							<Text className="font-mono text-xs text-default">{CLOUDFLARE_REDIRECT_URI}</Text>
						</View>
					</Card>
				</View>
			</ScrollView>
		</SafeAreaView>
	)
}
