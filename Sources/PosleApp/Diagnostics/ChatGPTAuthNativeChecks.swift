#if DEBUG
import Foundation
import Security

@MainActor
enum ChatGPTAuthNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw CheckFailure.failed("ChatGPT auth checks require an isolated --preview library")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw CheckFailure.failed("ChatGPT auth checks require a disposable library")
        }
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        try expect(ChatGPTSecurity.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE must match RFC 7636")
        let first = try ChatGPTSecurity.randomURLSafe(), second = try ChatGPTSecurity.randomURLSafe()
        try expect(first != second && first.count >= 43 && !first.contains("="), "State/nonce must use independent random bytes")
        let accepted = try ChatGPTSecurity.callback("/auth/callback?state=offline-state&code=code&client_id=oaiapp_offline", state: "offline-state", issuedClientID: nil)
        try expect(accepted.clientID == "oaiapp_offline", "Dynamic bootstrap cannot be saved as issued client")
        let returning = try ChatGPTSecurity.callback("/auth/callback?state=offline-state&code=code", state: "offline-state", issuedClientID: "oaiapp_offline")
        try expect(returning.clientID == "oaiapp_offline", "Reauthorization retains the selected client ID")
        for target in ["/callback?state=offline-state&code=code&client_id=oaiapp_offline", "/auth/callback?state=wrong&code=code&client_id=oaiapp_offline", "/auth/callback?state=offline-state&state=offline-state&code=code&client_id=oaiapp_offline", "/auth/callback?state=offline-state&code=code&client_id=dynamic_agent_client", "/auth/callback?state=offline-state&code=code", "/auth/callback?state=offline-state&code=code&client_id=oaiapp_other", "/auth/callback?state=offline-state&code=code&client_id=oaiapp_offline&iss=https%3A%2F%2Fexample.com"] {
            try rejects { _ = try ChatGPTSecurity.callback(target, state: "offline-state", issuedClientID: target.hasSuffix("oaiapp_other") ? "oaiapp_offline" : nil) }
        }
        do { _ = try ChatGPTSecurity.callback("/auth/callback?state=offline-state&error=access_denied", state: "offline-state", issuedClientID: nil); throw CheckFailure.failed("Consent denial was accepted") } catch ChatGPTSignInError.oauthDenied {}
        print("PASS: PKCE, random state, callback identity, duplicate parameters and denial validation")

        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil), let publicKey = SecKeyCopyPublicKey(key),
              let external = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw CheckFailure.failed("Could not create ephemeral fixture signing key") }
        let integers = try rsaIntegers(external)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "offline-key", "kty": "RSA", "alg": "RS256", "use": "sig", "n": ChatGPTSecurity.base64URL(integers.0), "e": ChatGPTSecurity.base64URL(integers.1)]]])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claims: [String: Any] = ["iss": ChatGPTSecurity.issuer, "sub": "offline-subject", "aud": "oaiapp_offline", "exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970, "nonce": "offline-nonce", "name": "Offline", "email": "offline@example.invalid"]
        func signed(_ claims: [String: Any], algorithm: String = "RS256") throws -> String {
            let header = ChatGPTSecurity.base64URL(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "offline-key"]))
            let body = ChatGPTSecurity.base64URL(try JSONSerialization.data(withJSONObject: claims))
            let input = header + "." + body
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil) as Data? else { throw CheckFailure.failed("Could not sign offline ID token") }
            return input + "." + ChatGPTSecurity.base64URL(signature)
        }
        let token = try signed(claims)
        let identity = try ChatGPTSecurity.verifyIDToken(token, clientID: "oaiapp_offline", nonce: "offline-nonce", expectedSubject: "offline-subject", jwks: jwks, now: now)
        try expect(identity.subject == "offline-subject", "Verified sub must identify the account")
        for (field, replacement) in [("iss", "https://example.invalid" as Any), ("aud", "another-client" as Any), ("exp", now.timeIntervalSince1970 as Any), ("nonce", "wrong-nonce" as Any), ("sub", "another-subject" as Any), ("exp", true as Any), ("nbf", now.timeIntervalSince1970 + 3600 as Any)] {
            var changed = claims; changed[field] = replacement
            let invalid = try signed(changed)
            try rejects { _ = try ChatGPTSecurity.verifyIDToken(invalid, clientID: "oaiapp_offline", nonce: "offline-nonce", expectedSubject: "offline-subject", jwks: jwks, now: now) }
        }
        try rejects { _ = try ChatGPTSecurity.verifyIDToken(signed(claims, algorithm: "none"), clientID: "oaiapp_offline", nonce: "offline-nonce", expectedSubject: nil, jwks: jwks, now: now) }
        let pieces = token.split(separator: "."); let corrupted = pieces[0] + "." + pieces[1] + "." + ChatGPTSecurity.base64URL(Data(repeating: 1, count: 256))
        try rejects { _ = try ChatGPTSecurity.verifyIDToken(corrupted, clientID: "oaiapp_offline", nonce: "offline-nonce", expectedSubject: nil, jwks: jwks, now: now) }
        try expect(ChatGPTSecurity.accountID(subject: "same", clientID: "one") != ChatGPTSecurity.accountID(subject: "same", clientID: "two"), "Workspace registrations sharing an email or subject must stay separate")
        print("PASS: actual RSA signature, issuer, client audience, expiry, nonce, subject, algorithm and tamper validation")

        let catalog = Data("{\"models\":[{\"slug\":\"hidden\",\"display_name\":\"Hidden\",\"visibility\":\"hidden\"},{\"slug\":\"second\",\"display_name\":\"Second\",\"visibility\":\"list\"},{\"slug\":\"first\",\"display_name\":\"First\",\"visibility\":\"list\"},{\"slug\":\"first\",\"display_name\":\"Duplicate\",\"visibility\":\"list\"}]}".utf8)
        let models = try ChatGPTSecurity.parseModels(catalog)
        try expect(models.map(\.id) == ["second", "first"] && models.first?.reasoningChoices == [], "Model catalog must preserve visible server ordering and avoid invented models/capabilities")
        try rejects { _ = try ChatGPTSecurity.parseModels(Data("{\"data\":[]}".utf8)) }
        let preview = ChatGPTAccount.fixture()
        try expect(preview.profile == nil && preview.models.isEmpty, "Preview must not load live credentials")
        print("PASS: account-specific model catalog, separate registration identity and isolated previews")
        try await ChatGPTSecurity.verifySessionLifecycle()
        print("PASS: concurrent refresh serializes one rotation, atomic replacement, account mismatch, temporary and terminal failures")
        try await ChatGPTSecurity.verifyLoopback()
        print("PASS: actual loopback ephemeral listener, bad-state rejection, valid callback and cancellation")
        let startup = try ChatGPTAccount.restoringFixture()
        try expect(startup.account.profile == nil, "The fixture must begin before asynchronous restoration")
        let restoredToken = try await startup.account.accessToken(expectedAccountID: startup.id)
        try expect(restoredToken == "offline-startup-access" && startup.account.profile?.id == startup.id, "An immediate queued request must wait for the saved account")
        do { _ = try await startup.account.accessToken(expectedAccountID: "other-account"); throw CheckFailure.failed("Startup restoration changed the queued account") } catch ChatGPTSignInError.accountChanged {}
        let catalogStartup = try ChatGPTAccount.restoringFixture()
        await catalogStartup.account.refreshModels()
        try expect(catalogStartup.account.models.map(\.id) == ["offline-model"], "Catalog loading must wait for initial restoration")
        let cancelledStartup = try ChatGPTAccount.restoringFixture()
        let cancelledJob = Task { try await cancelledStartup.account.accessToken(expectedAccountID: cancelledStartup.id) }
        cancelledJob.cancel()
        do { _ = try await cancelledJob.value; throw CheckFailure.failed("A cancelled startup job returned credentials") } catch is CancellationError {}
        let nextToken = try await cancelledStartup.account.accessToken(expectedAccountID: cancelledStartup.id)
        try expect(nextToken == "offline-startup-access", "One cancelled job must not cancel shared restoration")
        let superseded = try ChatGPTAccount.restoringFixture()
        superseded.account.cancelSignIn()
        do { _ = try await superseded.account.accessToken(expectedAccountID: superseded.id); throw CheckFailure.failed("A superseded snapshot restored an account") } catch ChatGPTSignInError.accountChanged {}
        try await Task.sleep(for: .milliseconds(50))
        try expect(superseded.account.profile == nil, "An old initial snapshot cannot resurrect a superseded session")
        print("PASS: startup token/catalog calls await one restore, cancellation is isolated and stale restore cannot replace account state")
        try await ChatGPTAccount.verifyCancelledCatalog()
        try await ChatGPTAccount.verifyCancelledSignIn()
        try ChatGPTAccount.verifyLoginHandoff()
        print("PASS: cancelled catalog requests preserve the selected model and account; cancelled sign-in tasks cannot open a browser; callback/terminal focus intents stay within the current login; cancellation, preview and stale attempts cannot focus")
        print("7 native ChatGPT auth checks passed (synthetic credentials only)")
    }
    private enum CheckFailure: Error { case failed(String) }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw CheckFailure.failed(message) } }
    private static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw CheckFailure.failed("Invalid authorization data was accepted")
    }
    private static func rsaIntegers(_ data: Data) throws -> (Data, Data) {
        let bytes = [UInt8](data); var offset = 0
        func element(_ tag: UInt8) throws -> Data {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw CheckFailure.failed("Invalid fixture DER") }
            offset += 1; var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                guard count > 0, count <= 4, offset + count <= bytes.count else { throw CheckFailure.failed("Invalid fixture DER length") }
                for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            }
            guard offset + length <= bytes.count else { throw CheckFailure.failed("Truncated fixture DER") }
            let value = Data(bytes[offset..<(offset + length)]); offset += length; return value
        }
        let sequence = try element(0x30)
        let nested = [UInt8](sequence); offset = 0
        // Parse PKCS#1 public-key INTEGERs from a separate cursor.
        func integer() throws -> Data {
            guard offset + 2 <= nested.count, nested[offset] == 2 else { throw CheckFailure.failed("Invalid RSA fixture") }
            offset += 1; var length = Int(nested[offset]); offset += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { guard offset < nested.count else { throw CheckFailure.failed("Invalid RSA fixture") }; length = (length << 8) | Int(nested[offset]); offset += 1 } }
            guard offset + length <= nested.count else { throw CheckFailure.failed("Invalid RSA fixture") }
            let value = Data(nested[offset..<(offset + length)]).drop(while: { $0 == 0 }); offset += length; return Data(value)
        }
        return (try integer(), try integer())
    }
}
#endif
