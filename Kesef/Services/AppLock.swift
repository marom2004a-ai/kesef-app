import Foundation
import LocalAuthentication
import Observation

/// נעילת אפליקציה ב-Face ID / Touch ID / קוד המכשיר (LocalAuthentication הרשמי).
@Observable
@MainActor
final class AppLock {
    var isLocked: Bool
    var lastError: String?
    private var backgroundedAt: Date?

    init() {
        isLocked = UserDefaults.standard.bool(forKey: AppSettings.Key.faceIDEnabled)
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: AppSettings.Key.faceIDEnabled) }

    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "קוד המכשיר"
        }
    }

    /// האם המכשיר תומך באימות (ביומטרי או קוד)
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func didEnterBackground() { backgroundedAt = .now }

    func willEnterForeground() {
        guard isEnabled else { isLocked = false; return }
        let grace = TimeInterval(UserDefaults.standard.integer(forKey: AppSettings.Key.lockAfterSeconds))
        if let t = backgroundedAt, Date.now.timeIntervalSince(t) >= grace { isLocked = true }
    }

    func unlock() async {
        guard isEnabled else { isLocked = false; return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "ביטול"
        do {
            // deviceOwnerAuthentication = ביומטרי עם נפילה לקוד המכשיר
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "פתיחת נתוני הכספים שלך")
            if ok { isLocked = false; lastError = nil }
        } catch {
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }

    /// הפעלה/כיבוי — דורש אימות מוצלח כדי לוודא שהמכשיר תומך
    func setEnabled(_ on: Bool) async -> Bool {
        if !on { UserDefaults.standard.set(false, forKey: AppSettings.Key.faceIDEnabled); return true }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            lastError = "במכשיר לא מוגדר קוד או Face ID."
            return false
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "הפעלת נעילה לאפליקציה")
            UserDefaults.standard.set(ok, forKey: AppSettings.Key.faceIDEnabled)
            return ok
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
