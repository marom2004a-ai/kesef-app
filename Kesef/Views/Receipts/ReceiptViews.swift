import SwiftUI
import SwiftData

/// הפקת קבלה — אותו מסך משולב של הכנסה עסקית + קבלה
struct IssueReceiptView: View {
    var body: some View { BusinessIncomeView() }
}

/// הגדרת חיבור ל-morning: סביבה + מפתחות API ב-Keychain + בדיקת חיבור
struct MorningSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MorningService.envKey) private var envRaw = MorningService.Environment.demo.rawValue
    @State private var clientId = ""
    @State private var secret = ""
    @State private var status: String?
    @State private var ok = false
    @State private var testing = false
    @State private var refresh = 0

    private var env: MorningService.Environment { MorningService.Environment(rawValue: envRaw) ?? .demo }

    var body: some View {
        Form {
            Section {
                Picker("סביבה", selection: $envRaw) {
                    ForEach(MorningService.Environment.allCases) { Text($0.shortLabel).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(env.label).font(.caption).foregroundStyle(.secondary)
            } footer: { Text("הדגמה: לנסות את המסך בלי חשבון. ניסיון: מפתחות Sandbox של morning. אמיתי: מסמכי מס רשמיים. לכל סביבה מפתחות נפרדים.") }

            if env != .demo {
            Section {
                LabeledContent("מצב", value: MorningService.isConfigured(env) ? "מוגדר ✓" : "לא מוגדר")
                    .id(refresh)
                TextField("Client ID", text: $clientId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                SecureField("Client Secret", text: $secret)
                    .environment(\.layoutDirection, .leftToRight)
                Button("שמירה מאובטחת") {
                    let i = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !i.isEmpty, !s.isEmpty else { status = "יש למלא את שני השדות."; ok = false; return }
                    ok = KeychainStore.set(i, for: MorningService.idAccount(env)) && KeychainStore.set(s, for: MorningService.secretAccount(env))
                    status = ok ? "נשמר ב-Keychain." : "השמירה נכשלה."
                    clientId = ""; secret = ""; refresh += 1
                }
                .disabled(clientId.isEmpty || secret.isEmpty)
                Button {
                    testing = true
                    Task {
                        do { try await MorningService.testConnection(env); ok = true; status = "החיבור ל-morning תקין ✓" }
                        catch { ok = false; status = error.localizedDescription }
                        testing = false
                    }
                } label: { HStack { if testing { ProgressView() }; Text("בדיקת חיבור (לא מפיק מסמך)") } }
                .disabled(!MorningService.isConfigured(env) || testing)
                if let status { Text(status).font(.footnote).foregroundStyle(ok ? Theme.income : Theme.expense) }
                if MorningService.isConfigured(env) {
                    Button("מחיקת המפתחות של הסביבה הזו", role: .destructive) {
                        KeychainStore.delete(MorningService.idAccount(env)); KeychainStore.delete(MorningService.secretAccount(env))
                        status = "המפתחות נמחקו."; ok = false; refresh += 1
                    }
                }
            } header: { Text("מפתחות API (\(env.shortLabel))") }
              footer: { Text("ב-morning: הגדרות ← כלים למפתחים ← API ← יצירת מפתח. מעתיקים את ה-ID וה-Secret ומדביקים כאן. המפתחות נשמרים רק ב-Keychain של האייפון ונשלחים רק ל-morning. גישת API דורשת מנוי שכולל אותה.") }
            }

            Section {
                Link(destination: URL(string: "https://app.greeninvoice.co.il/settings/developers/api")!) {
                    Label("פתיחת עמוד המפתחות ב-morning", systemImage: "arrow.up.right.square")
                }
            }
        }
        .navigationTitle("חיבור ל-morning")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סגירה") { dismiss() } } }
    }
}
