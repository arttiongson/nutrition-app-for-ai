import Foundation
import NutritionCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Live end-to-end check of NutritionAuth against the real Supabase backend.
// Env: SUPABASE_URL, PUBKEY, TEST_EMAIL (a throwaway). Cleaned up by the caller.
let env = ProcessInfo.processInfo.environment
guard let urlStr = env["SUPABASE_URL"], let key = env["PUBKEY"], let email = env["TEST_EMAIL"] else {
    print("set SUPABASE_URL, PUBKEY, TEST_EMAIL"); exit(2)
}

let auth = NutritionAuth(baseURL: URL(string: urlStr)!, apiKey: key)
let password = "Test12345!"

do {
    let signedUp = try await auth.signUp(email: email, password: password)
    print("✓ signUp → token(\(signedUp.accessToken.count) chars), expires \(signedUp.expiryDate)")

    let signedIn = try await auth.signIn(email: email, password: password)
    print("✓ signIn → token(\(signedIn.accessToken.count) chars)")

    let refreshed = try await auth.refresh()
    print("✓ refresh → rotated: \(refreshed.accessToken != signedIn.accessToken)")

    let token = try await auth.accessToken()
    print("✓ accessToken() → \(token.count) chars")
    print("LIVE AUTH OK ✅")
} catch {
    print("LIVE AUTH FAILED ❌: \(error)")
    exit(1)
}
