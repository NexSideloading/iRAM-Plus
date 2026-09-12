//
//  LoginViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import StosSign_API_NoCertificate
import StosSign_Auth

class LoginViewModel: ObservableObject {
    @Published var appleAccount = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var teamSelectionShow = false
    @Published var isLoginInProgress = false
    @Published private(set) var isVerificationCodeSubmitting = false
    @Published var logs = ""
    @Published var availableTeams: [Team] = []
    
    var progressCallback: ((Double, String) -> Void)?
    
    private var verificationCodeHandler: ((String?) -> Void)?
    private var isAuthenticationCancellationRequested = false
    
    func submitVerificationCode() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isVerificationCodeSubmitting,
                  let verificationCodeHandler = self.verificationCodeHandler else { return }

            self.verificationCodeHandler = nil
            self.isVerificationCodeSubmitting = true
            verificationCodeHandler(self.verificationCode)
        }
    }

    func cancelAuthentication() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isLoginInProgress else { return }

            self.isAuthenticationCancellationRequested = true

            let verificationCodeHandler = self.verificationCodeHandler
            self.verificationCodeHandler = nil
            self.needVerificationCode = false
            self.verificationCode = ""
            self.isVerificationCodeSubmitting = false

            verificationCodeHandler?(nil)
        }
    }
    
    func authenticate() async throws -> Bool {
        let shouldReturn = await MainActor.run {
            if isLoginInProgress {
                return true
            }
            return false
        }
        
        if shouldReturn {
            return false
        }

        await MainActor.run {
            logs = ""
            isLoginInProgress = true
            isAuthenticationCancellationRequested = false
        }

        await MainActor.run {
            progressCallback?(0.0, "Starting...")
        }

        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.logs.append("\(text)\n")
            }
        }

        AnisetteDataHelper.shared.loggingFunc = logging

        defer {
            // Only cleanup if we're not waiting for 2FA
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.needVerificationCode {
                    self.verificationCodeHandler = nil
                    self.appleAccount = ""
                    self.password = ""
                    self.verificationCode = ""
                    self.isLoginInProgress = false
                    self.isVerificationCodeSubmitting = false
                    self.isAuthenticationCancellationRequested = false
                }
            }
        }

        do {
            logging("=== Starting Authentication Process ===")
            logging("Apple Account: \(appleAccount)")
            
            await MainActor.run {
                progressCallback?(0.1, "Trying to get anisette data")
            }
            logging("Step 1: Fetching Anisette data...")
            let anisetteData = try await AnisetteDataHelper.shared.getAnisetteData()
            logging("Step 1 completed: Anisette data received successfully")
            await MainActor.run {
                progressCallback?(0.3, "Anisette data received")
            }

            await MainActor.run {
                progressCallback?(0.4, "Authenticating with Apple")
            }
            logging("Step 2: Starting Apple authentication...")
            logging("Using Anisette data - machineID: \(anisetteData.machineID.prefix(10))...")
            
            let (account, session) = try await AppleAPI.shared.authenticate(appleID: appleAccount, password: password, anisetteData: anisetteData) { [weak self] completionHandler in
                guard let self else {
                    logging("ERROR: Self is nil in authentication callback")
                    completionHandler(nil)
                    return
                }

                logging("2FA required, preparing verification UI")
                self.prepareForVerification(using: completionHandler)
            }

            logging("Step 2 completed: Apple authentication successful")
            logging("Account received successfully")
            logging("Session received: dsid=\(session.dsid)")

            await MainActor.run {
                progressCallback?(0.65, "Authentication successful")
            }

            await MainActor.run {
                guard !isAuthenticationCancellationRequested else {
                    logging("Authentication was cancelled by user")
                    return
                }
            }

            if await MainActor.run(body: { isAuthenticationCancellationRequested }) {
                logging("Throwing cancellation error")
                throw CancellationError()
            }

            logging("Step 3: Storing account and session in DataManager")
            await MainActor.run {
                DataManager.shared.model.account = account
                DataManager.shared.model.session = session
            }
            logging("Step 3 completed: Account and session stored")

            logging("Successfully signed in")
            await MainActor.run {
                progressCallback?(0.8, "Successfully signed in")
            }

            logging("Step 4: Fetching teams...")
            let teams = try await fetchTeams(for: account, session: session)
            logging("Step 4 completed: Successfully fetched \(teams.count) teams")
            logging("Teams: \(teams.map { String($0.identifier.prefix(8)) + "..." }.joined(separator: ", "))")
            await MainActor.run {
                availableTeams = teams
                progressCallback?(1.0, "Successfully fetched teams")
            }
            
            // Auto-select the first team for wizard flow
            await MainActor.run {
                if let firstTeam = teams.first {
                    DataManager.shared.model.team = firstTeam
                    logging("Auto-selected team: \(String(firstTeam.identifier.prefix(8)) + "...")")
                }
            }

            logging("=== Authentication Process Completed Successfully ===")
            return true
        } catch {
            logging("=== ERROR IN AUTHENTICATION PROCESS ===")
            logging("Error type: \(type(of: error))")
            logging("Error description: \(error.localizedDescription)")
            if let localizedError = error as? LocalizedError {
                logging("Localized error: \(localizedError.errorDescription ?? "N/A")")
                if let failureReason = localizedError.failureReason {
                    logging("Failure reason: \(failureReason)")
                }
            }
            logging("Error details: \(error)")
            
            if await MainActor.run(body: { isAuthenticationCancellationRequested }) {
                logging("Error was due to user cancellation")
                throw CancellationError()
            }
            logging("Throwing error to caller")
            throw error
        }
    }

    private func prepareForVerification(using handler: @escaping (String?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                handler(nil)
                return
            }
            
            guard !self.isAuthenticationCancellationRequested else {
                handler(nil)
                return
            }

            self.verificationCodeHandler = handler
            self.verificationCode = ""
            self.needVerificationCode = true
            self.isVerificationCodeSubmitting = false
            self.isLoginInProgress = false
            
            // Force UI refresh by triggering objectWillChange
            self.objectWillChange.send()
        }
    }
    
    func fetchTeams(for account: Account, session: AppleAPISession) async throws -> [Team]
    {
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.logs.append("\(text)\n")
            }
        }
        
        logging("Fetching teams for account")
        logging("Session dsid: \(session.dsid)")
        logging("Session anisette data available: \(session.anisetteData.machineID != "")")
        
        let fetchedTeams = try await AppleAPI.shared.fetchTeamsForAccount(account: account, session: session)
        logging("Received \(fetchedTeams.count) teams from Apple API")
        
        guard !fetchedTeams.isEmpty else {
            logging("ERROR: No teams returned from Apple API")
            throw "Unable to Fetch Team!"
        }

        logging("Teams fetched successfully")
        return fetchedTeams
    }
    
    func login() async throws {
        _ = try await authenticate()
    }
    
    func verifyTwoFactorCode(_ code: String) async throws {
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.logs.append("\(text)\n")
            }
        }
        
        logging("=== Starting 2FA Verification ===")
        logging(text: "Verification code provided: \(code.isEmpty ? "EMPTY" : "HAS_VALUE")")
        
        await MainActor.run {
            verificationCode = code
        }
        logging(text: "Submitting verification code to AppleAPI")
        submitVerificationCode()
        
        // Wait for authentication to complete with timeout
        let startTime = Date()
        var sessionSet = false
        var accountSet = false
        
        logging(text: "Waiting for authentication to complete (10 second timeout)...")
        while Date().timeIntervalSince(startTime) < 10 {
            if await MainActor.run(body: { DataManager.shared.model.session != nil }) {
                sessionSet = true
                logging(text: "Session is now set")
            }
            if await MainActor.run(body: { DataManager.shared.model.account != nil }) {
                accountSet = true
                logging(text: "Account is now set")
            }
            if sessionSet && accountSet {
                logging(text: "Both session and account are set - authentication complete")
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // Check if authentication succeeded
        if !sessionSet || !accountSet {
            logging(text: "ERROR: 2FA verification failed - sessionSet: \(sessionSet), accountSet: \(accountSet)")
            throw "Failed to verify 2FA code"
        }
        
        logging(text: "2FA verification successful, cleaning up state")
        // Cleanup after successful 2FA
        await MainActor.run {
            verificationCodeHandler = nil
            appleAccount = ""
            password = ""
            needVerificationCode = false
            verificationCode = ""
            isLoginInProgress = false
            isVerificationCodeSubmitting = false
            isAuthenticationCancellationRequested = false
        }
        logging(text: "=== 2FA Verification Completed Successfully ===")
    }
    
    func resetVerificationCodeState() {
        isVerificationCodeSubmitting = false
        verificationCode = ""
    }
}
