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
        //
        // Explicitly `@Sendable`: written inside a @MainActor method the
        // closure would inherit main-actor isolation, and on macOS
        // AuthenticationServices invokes it from its XPC reply queue — the
        // runtime isolation check then traps (SIGTRAP in
        // dispatch_assert_queue). iOS happens to call back on main, which
        // is why only the Mac crashed. The listener is an actor, so the
        // hop inside is safe from any thread.
        let web = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: nil) {
            @Sendable _, error in
            if error != nil {
                Task { await listener.cancel() }
            }
        }
        web.presentationContextProvider = self
        web.prefersEphemeralWebBrowserSession = false
        webSession = web

        defer {
            webSession?.cancel()
            webSession = nil
        }
        // A refused presentation (no anchor, a sheet already up) fires no
        // completion handler, so nothing would ever unblock the listener —
        // fail here instead of waiting out the timeout on a sheet the user
        // never saw.
        guard web.start() else {
            await listener.cancel()
            throw LoopbackRedirectListener.RedirectError.presentationFailed
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
