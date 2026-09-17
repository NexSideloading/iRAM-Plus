import XCTest
import SideSign
@testable import iRAM_Plus

@MainActor
final class LoginViewModelTests: XCTestCase {
    private func waitForPrompt(_ model: LoginViewModel) async {
        for _ in 0..<1000 {
            if model.needVerificationCode && !model.isVerificationCodeSubmitting { return }
            await Task.yield()
        }
        XCTFail("Verification prompt did not appear")
    }

    func testCodeValidationAndDuplicateSubmission() async {
        let model = LoginViewModel()
        let task = Task { await model.awaitVerification(.trustedDevice()) }
        await waitForPrompt(model)
        for invalid in ["", "12345", "1234567", "abcdef", "１２３４５６"] {
            model.verificationCode = invalid
            XCTAssertFalse(model.canSubmitVerificationCode)
            model.submitVerificationCode()
            XCTAssertFalse(model.isVerificationCodeSubmitting)
        }
        model.verificationCode = "012345"
        XCTAssertTrue(model.canSubmitVerificationCode)
        model.submitVerificationCode()
        model.submitVerificationCode() // Must not resume the continuation twice.
        guard case .verificationCode("012345") = await task.value else {
            return XCTFail("Expected the code, preserving its leading zero")
        }
        XCTAssertTrue(model.isVerificationCodeSubmitting)
        XCTAssertEqual(model.verificationCode, "")
    }

    func testDeliveryUsesSelectedPhoneID() async {
        let model = LoginViewModel()
        let phones = [TrustedPhoneNumber(id: "2", number: "••12"), TrustedPhoneNumber(id: "7", number: "••34")]
        let task = Task { await model.awaitVerification(.selectDeliveryMethod(preferredMode: .sms, phoneNumbers: phones)) }
        await waitForPrompt(model)
        XCTAssertTrue(model.isChoosingDeliveryMethod)
        model.verificationCode = "123456"
        XCTAssertFalse(model.canSubmitVerificationCode)
        model.selectedPhoneID = "7"
        model.requestSMSCode()
        guard case .requestSMS(phoneID: "7") = await task.value else {
            return XCTFail("Must use the selected phone ID, not a hardcoded default")
        }
    }

    func testIncorrectCodeCanRetryAndSwitchToVoice() async {
        let model = LoginViewModel()
        let first = Task { await model.awaitVerification(.trustedDevice()) }
        await waitForPrompt(model)
        model.verificationCode = "123456"
        model.submitVerificationCode()
        _ = await first.value
        let retry = Task { await model.awaitVerification(.sms(phoneNumbers: [], activeID: "2", error: "Incorrect code")) }
        await waitForPrompt(model)
        XCTAssertEqual(model.verificationRequest?.error, "Incorrect code")
        XCTAssertEqual(model.verificationCode, "")
        XCTAssertFalse(model.isVerificationCodeSubmitting)
        model.requestVoiceCode()
        guard case .requestVoice(phoneID: "2") = await retry.value else {
            return XCTFail("Retry must preserve the active phone ID")
        }
    }

    func testCancellationResumesPendingChallenge() async {
        let model = LoginViewModel()
        let task = Task { await model.awaitVerification(.trustedDevice()) }
        await waitForPrompt(model)
        model.cancelAuthentication()
        model.cancelAuthentication()
        guard case .cancel = await task.value else { return XCTFail("Expected cancellation") }
        XCTAssertFalse(model.needVerificationCode)
        let subsequent = await model.awaitVerification(.trustedDevice())
        guard case .cancel = subsequent else { return XCTFail("Cancelled attempt must not prompt again") }
    }

    func testTaskCancellationResumesPendingChallenge() async {
        let model = LoginViewModel()
        let task = Task { await model.awaitVerification(.trustedDevice()) }
        await waitForPrompt(model)
        task.cancel()
        guard case .cancel = await task.value else { return XCTFail("Expected task cancellation") }
    }
}
