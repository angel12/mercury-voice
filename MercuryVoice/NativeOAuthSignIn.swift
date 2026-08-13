import AuthenticationServices
import Foundation
import HermesKit

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Runs one RFC 8252 sign-in: loopback listener + system browser sheet +
/// code-for-tokens exchange (issue #51). The gateway only accepts loopback
/// IP-literal redirect URIs (no custom schemes), so completion is detected
/// by the listener catching the redirect — the browser sheet's own callback
/// never fires and is used purely to observe user cancellation.
@MainActor
final class NativeOAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?

    func signIn(
        endpoint: ServerEndpoint, provider: AuthProviderInfo
    ) async throws -> PasswordSession {
        let challenge = PKCEChallenge()
        let state = PKCEChallenge.randomState()
        let listener = LoopbackRedirectListener(expectedState: state)
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)/oauth/callback"
        let authorizeURL = HermesAuthenticator.nativeAuthorizeURL(
            endpoint: endpoint,
            provider: provider.name,
            challenge: challenge,
            redirectURI: redirectURI,
            state: state)

        // No callbackURLScheme: the redirect goes to the loopback listener,
        // not back through the browser API. The completion handler fires
        // only when the user dismisses the sheet — unblock the listener so
        // the await below throws .cancelled.
        let web = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: nil) {
            _, error in
            if error != nil {
                Task { await listener.cancel() }
            }
        }
        web.presentationContextProvider = self
        web.prefersEphemeralWebBrowserSession = false
        webSession = web
        web.start()

        defer {
            webSession?.cancel()
            webSession = nil
        }
        let code: String
        do {
            code = try await listener.waitForCode()
        } catch {
            await listener.cancel()
            throw error
        }
        return try await HermesAuthenticator.redeemNativeCode(
            endpoint: endpoint,
            provider: provider.name,
            code: code,
            verifier: challenge.verifier)
    }

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
                return UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            #else
                return NSApplication.shared.keyWindow
                    ?? NSApplication.shared.windows.first
                    ?? ASPresentationAnchor()
            #endif
        }
    }
}
