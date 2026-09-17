import SwiftUI
import SideSign
import StosSign_API
import StosSign_Common

@MainActor
class LoginViewModel: ObservableObject {
    @Published var appleAccount = ""
    @Published var password = ""
    @Published private(set) var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var teamSelectionShow = false
    @Published private(set) var isLoginInProgress = false
    @Published private(set) var isVerificationCodeSubmitting = false
    @Published var logs = ""
    @Published var availableTeams: [StosSign_Common.Team] = []
    @Published private(set) var verificationRequest: TwoFactorRequest?
    @Published private(set) var phoneNumbers: [TrustedPhoneNumber] = []
    @Published var selectedPhoneID = ""

    var progressCallback: ((Double, String) -> Void)?
    private var verificationContinuation: CheckedContinuation<TwoFactorResponse, Never>?
    private var isAuthenticationCancellationRequested = false
    private var authenticationTransport: URLSession?

    var isChoosingDeliveryMethod: Bool {
        if case .selectDeliveryMethod = verificationRequest { return true }
        return false
    }

    var verificationMessage: String {
        switch verificationRequest {
        case .selectDeliveryMethod: return "Choose how to receive your verification code."
        case .trustedDevice: return "Enter the six-digit code shown on your trusted Apple device."
        case .sms: return "Enter the six-digit code sent to your trusted phone number."
        case .voice: return "Enter the six-digit code from Apple's phone call."
        case nil: return ""
        }
    }

    var canSubmitVerificationCode: Bool {
        verificationCode.count == 6 && verificationCode.utf8.allSatisfy { (48...57).contains($0) }
            && verificationContinuation != nil && !isChoosingDeliveryMethod
    }

    func submitVerificationCode() {
        guard canSubmitVerificationCode else { return }
        respondToVerification(.verificationCode(verificationCode))
    }

    func requestTrustedDeviceCode() { respondToVerification(.requestTrustedDevice) }
    func requestSMSCode() { respondToVerification(.requestSMS(phoneID: selectedPhoneID)) }
    func requestVoiceCode() { respondToVerification(.requestVoice(phoneID: selectedPhoneID)) }

    private func respondToVerification(_ response: TwoFactorResponse) {
        guard let continuation = verificationContinuation else { return }
        verificationContinuation = nil
        isVerificationCodeSubmitting = true
        verificationCode = ""
        continuation.resume(returning: response)
    }

    func cancelAuthentication() {
        guard isLoginInProgress || verificationContinuation != nil else { return }
        isAuthenticationCancellationRequested = true
        respondToVerification(.cancel)
        authenticationTransport?.invalidateAndCancel()
        needVerificationCode = false
    }

    func awaitVerification(_ request: TwoFactorRequest) async -> TwoFactorResponse {
        guard !isAuthenticationCancellationRequested, !Task.isCancelled else { return .cancel }
        verificationRequest = request
        switch request {
        case .selectDeliveryMethod(_, let numbers):
            phoneNumbers = numbers
            selectedPhoneID = numbers.first?.id ?? ""
        case .sms(let numbers, let activeID, _), .voice(let numbers, let activeID, _):
            phoneNumbers = numbers
            selectedPhoneID = activeID
        case .trustedDevice: break
        }
        verificationCode = ""
        needVerificationCode = true
        isVerificationCodeSubmitting = false
        return await withTaskCancellationHandler {
            await withCheckedContinuation { verificationContinuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAuthentication() }
        }
    }

    func authenticate() async throws -> Bool {
        guard !isLoginInProgress else { return false }
        isLoginInProgress = true
        isAuthenticationCancellationRequested = false
        logs = "Starting Apple Account authentication.\n"
        availableTeams = []
        DataManager.shared.model.account = nil
        DataManager.shared.model.session = nil
        DataManager.shared.model.team = nil
        defer {
            authenticationTransport?.invalidateAndCancel()
            authenticationTransport = nil
            verificationContinuation?.resume(returning: .cancel)
            verificationContinuation = nil
            needVerificationCode = false
            verificationRequest = nil
            phoneNumbers = []
            selectedPhoneID = ""
            verificationCode = ""
            password = ""
            appleAccount = ""
            isVerificationCodeSubmitting = false
            isLoginInProgress = false
            AnisetteDataHelper.shared.loggingFunc = nil
        }

        do {
            progressCallback?(0.1, "Getting device authentication data")
            let anisette = try await AnisetteDataHelper.shared.getAnisetteData()
            try checkCancellation()
            let data = SideSign.AnisetteData(
                machineID: anisette.machineID, oneTimePassword: anisette.oneTimePassword,
                localUserID: anisette.localUserID, routingInfo: String(anisette.routingInfo),
                deviceID: anisette.deviceUniqueIdentifier, serialNumber: anisette.deviceSerialNumber,
                clientInfo: anisette.deviceDescription,
                userAgent: AnisetteDataHelper.shared.userAgent ?? "AuthKit/1 (Macintosh; OS X 27.0) (com.apple.akd/1.0)",
                clientTime: ISO8601DateFormatter().string(from: anisette.date),
                locale: anisette.locale.identifier, timeZone: anisette.timeZone.abbreviation() ?? "UTC"
            )
            var headers = SideSignHeaders()
            // Keep GrandSlam consistent with the anisette client identity.
            headers.grandSlam.userAgent = data.userAgent
            // Use a private cookie store for each sign-in, retaining cookies throughout 2FA.
            let transport = URLSession(configuration: .ephemeral)
            authenticationTransport = transport
            let portal = DeveloperPortal(session: transport, customHeaders: headers)
            progressCallback?(0.4, "Signing in with Apple")
            let result = try await portal.authenticate(
                appleID: appleAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password, anisetteData: data, xcodeVersion: "27.0 (27A5218g)",
                accountRepairHandler: { _, message in
                    throw NSError(domain: "AppleAccountRepair", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(message) Visit account.apple.com to review your account, then try again."
                    ])
                },
                verificationHandler: { [weak self] request in
                    guard let self else { return .cancel }
                    return await self.awaitVerification(request)
                }
            )
            try checkCancellation()
            needVerificationCode = false
            progressCallback?(0.8, "Fetching developer teams")
            let session = StosSign_API.AppleAPISession(
                dsid: result.session.dsid, authToken: result.session.authToken, anisetteData: anisette
            )
            guard let personID = Int(result.account.identifier) else { throw URLError(.cannotParseResponse) }
            let accountData = try JSONSerialization.data(withJSONObject: [
                "email": result.account.appleID, "personId": personID,
                "dsFirstName": result.account.firstName, "dsLastName": result.account.lastName
            ])
            let account = try JSONDecoder().decode(StosSign_Common.Account.self, from: accountData)
            let teams = try await StosSign_API.AppleAPI.shared.fetchTeamsForAccount(account: account, session: session)
            try checkCancellation()
            guard let firstTeam = teams.first else { throw "Unable to fetch a developer team for this account." }
            // Publish only a complete session. The original sign-in task owns navigation.
            DataManager.shared.model.account = account
            DataManager.shared.model.session = session
            DataManager.shared.model.team = firstTeam
            availableTeams = teams
            progressCallback?(1, "Signed in successfully")
            logs += "Authentication and team lookup succeeded.\n"
            return true
        } catch {
            if isAuthenticationCancellationRequested || Task.isCancelled { throw CancellationError() }
            // Avoid dumping server payloads, tokens, or personal identifiers into copyable logs.
            logs += "Sign-in failed (\((error as NSError).domain), \((error as NSError).code)).\n"
            throw error
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if isAuthenticationCancellationRequested { throw CancellationError() }
    }

    func login() async throws { _ = try await authenticate() }

    func resetVerificationCodeState() { verificationCode = "" }
}
