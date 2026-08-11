#if os(iOS) || os(watchOS)
    import Foundation
    import HermesKit
    import WatchConnectivity

    /// Mirrors the saved server + credentials to the paired watch so the
    /// watch app can reach the backend on its own over WiFi/cellular
    /// (issue #34). The iPhone pushes after every validated connect;
    /// the watch adopts what arrives into its keychain and connects.
    ///
    /// `updateApplicationContext` keeps only the newest snapshot and
    /// delivers it whenever the watch is next reachable, so no explicit
    /// retry or queue management is needed.
    final class CredentialSync: NSObject, WCSessionDelegate, @unchecked Sendable {
        static let shared = CredentialSync()

        private struct Payload: Codable {
            var endpointKey: String
            var credentials: ServerCredentials?
        }

        private static let contextKey = "server"

        func activate() {
            guard WCSession.isSupported() else { return }
            WCSession.default.delegate = self
            WCSession.default.activate()
        }

        // MARK: iPhone side (push)

        #if os(iOS)
            func push(endpoint: ServerEndpoint, credentials: ServerCredentials?) {
                guard WCSession.isSupported() else { return }
                let session = WCSession.default
                guard session.activationState == .activated,
                    session.isPaired,
                    session.isWatchAppInstalled,
                    let data = try? JSONEncoder().encode(
                        Payload(endpointKey: endpoint.key, credentials: credentials))
                else { return }
                try? session.updateApplicationContext([Self.contextKey: data])
            }

            /// Push the last-used server, so a watch app installed after the
            /// phone connected still receives credentials.
            private func pushCurrent() {
                guard let key = UserDefaults.standard.string(forKey: "lastServer"),
                    let parsed = try? ServerEndpoint.parse(key)
                else { return }
                push(
                    endpoint: parsed.endpoint,
                    credentials: KeychainTokenStore().credentials(for: parsed.endpoint))
            }

            func sessionDidBecomeInactive(_ session: WCSession) {}

            func sessionDidDeactivate(_ session: WCSession) {
                // A new watch was paired; re-activate for it.
                session.activate()
            }

            func sessionWatchStateDidChange(_ session: WCSession) {
                pushCurrent()
            }
        #endif

        func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: (any Error)?
        ) {
            #if os(iOS)
                if activationState == .activated { pushCurrent() }
            #endif
        }

        // MARK: Watch side (receive)

        #if os(watchOS)
            func session(
                _ session: WCSession,
                didReceiveApplicationContext applicationContext: [String: Any]
            ) {
                guard let data = applicationContext[Self.contextKey] as? Data,
                    let payload = try? JSONDecoder().decode(Payload.self, from: data),
                    let parsed = try? ServerEndpoint.parse(payload.endpointKey)
                else { return }
                Task { @MainActor in
                    AppModel.shared.adoptSyncedServer(
                        endpoint: parsed.endpoint, credentials: payload.credentials)
                }
            }
        #endif
    }
#endif
