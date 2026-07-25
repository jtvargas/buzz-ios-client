import LocalAuthentication

/// Device-owner authentication, behind a seam so the key-reveal flow can be tested
/// without a real biometric prompt.
protocol DeviceAuthenticating: Sendable {
    /// Prompts for Face ID / Touch ID, falling back to the device passcode. Returns
    /// `true` only on a successful authentication; any failure, cancellation, or an
    /// unavailable policy returns `false`.
    func authenticate(reason: String) async -> Bool
}

/// The production authenticator over `LocalAuthentication`.
///
/// Uses `.deviceOwnerAuthentication` (biometrics with a passcode fallback) rather
/// than the biometrics-only policy, so a device without enrolled biometrics can
/// still gate the reveal behind its passcode. If neither is available the policy
/// cannot be evaluated and the reveal is refused.
struct BiometricAuth: DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
