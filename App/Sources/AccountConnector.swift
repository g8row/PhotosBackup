import Foundation

/// Drives the credential half of the flow: everything from a captured
/// oauth_token onward. `AccountConnectView` reads the token in-app and passes
/// it to `ingestWebToken`; this type exchanges it and wires up the account.
@MainActor
final class AccountConnector: ObservableObject {
    let log: ProbeLog
    @Published var running = false
    /// Called with a usable exchange result so the Photos side can adopt the
    /// credential. Set by the app entry point.
    var onExchange: ((TokenExchange.Result) async -> Void)?
    /// Held in memory only, for the life of the process. A fresh oauth_token
    /// costs a full interactive sign-in, so while the Photos wire format is
    /// being debugged step 9 has to be repeatable against the same credential.
    @Published private(set) var lastResult: TokenExchange.Result?

    init(log: ProbeLog) {
        self.log = log
    }

    /// Capture path for the in-app WKWebView connector: the app reads the
    /// HttpOnly `oauth_token` straight from its own web view's cookie store, so
    /// there is no extension, host-permission grant, or native handoff to record
    /// — only the read and everything downstream of it. See AccountConnectView.
    func ingestWebToken(_ token: String) async {
        log.set(ProbeLog.extensionEnabled, .passed, "Google sign-in completed in-app")
        log.set(ProbeLog.hostPermission, .passed, "oauth_token cookie present in the web view store")
        log.set(ProbeLog.cookieRead, .passed, "read from the app's WKWebView cookie store (HttpOnly)")
        log.set(ProbeLog.nativeHandoff, .passed, "captured in-process — no extension handoff")
        log.set(ProbeLog.appIngest, .passed, "token length \(token.count); web view session discarded")
        await runExchange(oauthToken: token)
    }

    func runExchange(oauthToken: String) async {
        guard !running else { return }
        running = true
        defer { running = false }

        log.reset(from: ProbeLog.masterToken)
        log.set(ProbeLog.masterToken, .running)

        let result: TokenExchange.Result
        do {
            result = try await TokenExchange.run(oauthToken: oauthToken)
        } catch let f as TokenExchange.Failure {
            let failedStep = f.stage == "photos token" ? ProbeLog.photosToken : ProbeLog.masterToken
            if failedStep == ProbeLog.photosToken { log.set(ProbeLog.masterToken, .passed) }
            log.set(failedStep, .failed, f.message)
            DiagnosticEventLog.shared.record("account", "Sign-in failed while getting the \(f.stage): \(f.message)", level: .error)
            return
        } catch {
            log.set(ProbeLog.masterToken, .failed, error.localizedDescription)
            DiagnosticEventLog.shared.record("account", "Sign-in failed: \(error.localizedDescription)", level: .error)
            return
        }

        log.set(ProbeLog.masterToken, .passed,
                "account: \(result.email) · androidId: \(result.androidId)")
        log.set(ProbeLog.photosToken, result.encrypted ? .skipped : .passed,
                result.encrypted
                    ? "TokenEncrypted=1 — bound token, not decoded by this connector"
                    : "access token issued" + (result.photosTokenExpiry.map { ", expires \(Self.rel($0))" } ?? ""))

        if result.encrypted {
            log.set(ProbeLog.readAccess, .skipped, "skipped: no usable access token")
            DiagnosticEventLog.shared.record(
                "account",
                "Sign-in returned a device-bound token, which this app cannot use",
                level: .error
            )
            return
        }

        DiagnosticEventLog.shared.record("account", "Sign-in completed and the Google token was exchanged")
        lastResult = result
        await onExchange?(result)
        await checkReadAccess(result)
    }

    /// Re-run step 9 against the credential from the last exchange. The Photos
    /// access token outlives the single-use oauth_token by many hours, so this
    /// is the cheap way to iterate on the read path.
    func rerunReadAccess() async {
        guard let result = lastResult, !running else { return }
        running = true
        defer { running = false }
        await checkReadAccess(result)
    }

    private func checkReadAccess(_ result: TokenExchange.Result) async {
        log.set(ProbeLog.readAccess, .running)
        do {
            let client = try GPMCClient(authData: result.authData)
            try await client.validateReadAccess()
            log.set(ProbeLog.readAccess, .passed, "dummy hash lookup accepted by photosdata-pa")
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.set(ProbeLog.readAccess, .failed, detail)
            DiagnosticEventLog.shared.record("account", "The first read-only request after sign-in failed: \(detail)", level: .warning)
        }
    }

    static func rel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
