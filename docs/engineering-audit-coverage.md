# Audit coverage inventory

Baseline: `6cd7a539292936d2a8605b865de638b08e4fb4c8`. 106 tracked files. See `engineering-audit.md` for audit methods, findings and limitations. Source/test coverage includes complete subsystem reads by parallel reviewers plus primary cross-boundary/change verification. Binary assets received metadata/reference checks, not visual QA.

## Build / documentation / asset metadata

- `.gitignore`
- `LICENSE`
- `MercuryVoice.xcodeproj/project.pbxproj`
- `MercuryVoice.xcodeproj/xcshareddata/xcschemes/MercuryVoice.xcscheme`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `MercuryVoice/Assets.xcassets/Contents.json`
- `MercuryVoice/Info.plist`
- `MercuryVoice/MercuryVoice.entitlements`
- `MercuryVoice/PrivacyInfo.xcprivacy`
- `MercuryVoiceWidgets/Info.plist`
- `Packages/MercuryVoiceCore/Package.swift`
- `README.md`
- `docs/privacy-policy.md`
- `docs/support.md`

## App / Shared / widget Swift

- `MercuryVoice/AppModel.swift`
- `MercuryVoice/AppShortcuts.swift`
- `MercuryVoice/AudioDevicePicker.swift`
- `MercuryVoice/BrowseView.swift`
- `MercuryVoice/ConnectView.swift`
- `MercuryVoice/ConversationActivityController.swift`
- `MercuryVoice/ConversationController.swift`
- `MercuryVoice/ConversationView.swift`
- `MercuryVoice/DevChatView.swift`
- `MercuryVoice/KeepScreenAwake.swift`
- `MercuryVoice/MercuryVoiceApp.swift`
- `MercuryVoice/MuteHotkey.swift`
- `MercuryVoice/NativeOAuthSignIn.swift`
- `MercuryVoice/SettingsView.swift`
- `MercuryVoice/SystemLinks.swift`
- `MercuryVoice/ThemePreference.swift`
- `MercuryVoiceWidgets/MercuryVoiceWidgets.swift`
- `Shared/ConversationActivitySupport.swift`

## Binary documentation / icon assets (metadata only)

- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-128.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-128@2x.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-16.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-16@2x.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-256.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-256@2x.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-32.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-32@2x.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-512.png`
- `MercuryVoice/Assets.xcassets/AppIcon.appiconset/icon-mac-512@2x.png`
- `pics/01-connect.png`
- `pics/02-workspaces.png`
- `pics/03-listening.png`
- `pics/04-conversation.png`
- `pics/05-lock-screen.png`

## Package source

- `Packages/MercuryVoiceCore/Sources/HermesKit/GatewayClient.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/GatewayEvent.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/HermesAuthenticator.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/HermesConnection.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/HermesError.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/JSONValue.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/KeychainTokenStore.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/Models.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/NativeOAuth.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/RESTClient.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/ServerCredentials.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/ServerEndpoint.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/SessionAPI.swift`
- `Packages/MercuryVoiceCore/Sources/HermesKit/VoiceClientConfig.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/AgentTurnTracker.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/AudioCaptureService.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/AudioDevices.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/AudioSessionManager.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/BargeDetector.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/BargeInMonitor.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/ConversationCues.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/ConversationEngine.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/ConversationTypes.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/DirectVoice.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/EchoGuard.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/FallbackClipPlayer.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/HermesSpeechOutput.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/MicRecorder.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/MicrophoneAuthorization.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/PCMStreamPlayer.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/RateLockedResampler.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/SpeakStreamSession.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/SpeechText.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/StopWords.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/TurnSilencePreference.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/VoiceConstants.swift`
- `Packages/MercuryVoiceCore/Sources/VoiceEngine/WAVEncoder.swift`

## Package tests

- `Packages/MercuryVoiceCore/Tests/HermesKitTests/GatewayCloseTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/KeychainTokenStoreTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/NativeOAuthTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/PendingPromptDecodingTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/ProfileInfoDecodingTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/ProjectDecodingTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/RPCErrorReasonTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/ReconnectVoiceDecodingTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/ServerCredentialsTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/ServerEndpointTests.swift`
- `Packages/MercuryVoiceCore/Tests/HermesKitTests/SessionUsageDecodingTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/AgentTurnTrackerTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/AudioCueTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/BargeInMonitorTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/ConversationEngineTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/DirectVoiceTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/EngineRecoveryTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/EngineTestSupport.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/MicrophoneAuthorizationTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/RateLockedResamplerTests.swift`
- `Packages/MercuryVoiceCore/Tests/VoiceEngineTests/TextProcessingTests.swift`
