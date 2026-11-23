import SwiftUI
import SwiftData

/// צ'אט עם היועצת הפיננסית (Claude). שלושה מצבים: הסכמה → הגדרת מפתח → שיחה.
struct AdvisorChatView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(ClaudeAdvisorService.consentKey) private var consent = false
    @State private var hasKey = ClaudeAdvisorService.hasKey
    @State private var service = ClaudeAdvisorService()
    @State private var messages: [ChatLine] = []
    @State private var input = ""
    @State private var sending = false
    @State private var error: String?
    @State private var started = false
    @State private var showSettings = false

    struct ChatLine: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    static let suggestions = [
        "על מה אני מוציא יותר מדי החודש?",
        "מה מיותר ואפשר לבטל?",
        "כמה אני יכול לחסוך בחודש בלי לפגוע בהתחייבויות?",
        "תני לי תוכנית חיסכון ל-3 חודשים",
        "איך נראה החודש העסקי אחרי מע״מ וחלוקה עם מרום?",
        "האם אני בדרך למינוס?"
    ]

    var body: some View {
        Group {
            if !consent { ConsentView { consent = true } }
            else if !hasKey { APIKeySetupView { hasKey = ClaudeAdvisorService.hasKey } }
            else { chat }
        }
        .navigationTitle("היועצת")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if consent && hasKey {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("שיחה חדשה (עם נתונים עדכניים)") { restart() }
                        Button("הגדרות יועצת") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AdvisorSettingsView(onKeyRemoved: { hasKey = false }, onConsentRevoked: { consent = false })
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        intro
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if sending {
                            HStack(spacing: 8) { ProgressView(); Text("היועצת חושבת…").font(.subheadline).foregroundStyle(.secondary) }
                                .id("typing")
                        }
                        if let error { ErrorBanner(message: error) }
                        if messages.isEmpty { suggestionsView }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("שאל את היועצת…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button { send(input) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            .padding(.horizontal).padding(.vertical, 8)
            if service.usage.input + service.usage.output > 0 {
                Text("עלות משוערת לשיחה: $\(NSDecimalNumber(decimal: service.usage.estimatedUSD).stringValue.prefix(6))")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 4)
            }
        }
        .onAppear { if !started { restart() } }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("היי! אני היועצת הפיננסית שלך.").font(.headline)
                Text("אני רואה סיכום של כל התנועות, החיובים הקבועים, התקציבים, המע״מ והחלוקה עם השותף — ועונה לפי הנתונים שלך בלבד. ההמלצות אינן תחליף לייעוץ מקצועי.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("אפשר להתחיל מאחת מאלה:").font(.caption).foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { s in
                Button { send(s) } label: {
                    Text(s).font(.subheadline).multilineTextAlignment(.leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bubble(_ m: ChatLine) -> some View {
        HStack {
            if !m.fromUser { Spacer(minLength: 30) }
            Text(m.text)
                .textSelection(.enabled)
                .padding(12)
                .foregroundStyle(m.fromUser ? Color.white : Color.primary)
                .background(m.fromUser ? Theme.accent : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if m.fromUser { Spacer(minLength: 30) }
        }
        .frame(maxWidth: .infinity, alignment: m.fromUser ? .leading : .trailing)
    }

    private func restart() {
        service.startConversation(context: context)
        messages = []
        error = nil
        started = true
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !sending else { return }
        input = ""
        error = nil
        messages.append(ChatLine(fromUser: true, text: q))
        sending = true
        Task {
            do {
                let answer = try await service.ask(q)
                messages.append(ChatLine(fromUser: false, text: answer))
            } catch {
                self.error = error.localizedDescription
                if case .invalidKey? = error as? ClaudeAdvisorService.AdvisorError { hasKey = ClaudeAdvisorService.hasKey }
            }
            sending = false
        }
    }
}

/// מסך הסכמה — מה נשלח ולאן, לפני השימוש הראשון
struct ConsentView: View {
    var onAccept: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("יועצת AI לחיסכון").font(.title2.bold())
                Text("היועצת משתמשת ב-Claude של חברת Anthropic, שרץ בענן. כדי לענות, האפליקציה שולחת לשרתי Anthropic:")
                VStack(alignment: .leading, spacing: 6) {
                    Label("סיכומים חודשיים, קטגוריות ותקציבים", systemImage: "checkmark")
                    Label("שמות בתי עסק, תאריכים וסכומים של תנועות אחרונות", systemImage: "checkmark")
                    Label("חיובים קבועים, מע״מ וחלוקה עם השותף", systemImage: "checkmark")
                    Label("השאלות שאתה כותב", systemImage: "checkmark")
                }.font(.subheadline)
                Text("לא נשלחים: שמות חשבונות, מספרי כרטיס, הערות, קבלות או סיסמאות.").font(.subheadline.weight(.semibold))
                Text("המידע נשלח רק כשאתה שואל שאלה. בלי ההסכמה הזו שום דבר לא יוצא מהאייפון, וכל שאר האפליקציה ממשיכה לעבוד מקומית. אפשר לבטל בכל רגע בהגדרות היועצת.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(action: onAccept) {
                    Text("אני מסכים — המשך").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.gold)
                .padding(.top, 8)
            }
            .padding()
        }
    }
}

/// הגדרת מפתח API — המשתמש מדביק בעצמו, נשמר ב-Keychain
struct APIKeySetupView: View {
    var onSaved: () -> Void
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("כדי להשתמש ביועצת צריך מפתח API של Anthropic (תשלום לפי שימוש, בדרך כלל אגורות לשאלה).")
                Link(destination: URL(string: "https://platform.claude.com")!) {
                    Label("פתיחת platform.claude.com ליצירת מפתח", systemImage: "arrow.up.right.square")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. התחבר / הירשם, והוסף אמצעי תשלום (Billing).")
                    Text("2. Settings ← API Keys ← Create Key.")
                    Text("3. העתק את המפתח (מתחיל ב-sk-ant-) והדבק כאן.")
                    Text("טיפ: אפשר להגדיר שם תקרת הוצאה חודשית.").foregroundStyle(.secondary)
                }.font(.footnote)
            }
            Section {
                SecureField("sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                Button("שמירה מאובטחת") {
                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard k.hasPrefix("sk-ant-") else { error = "המפתח צריך להתחיל ב-sk-ant-"; return }
                    if KeychainStore.set(k, for: ClaudeAdvisorService.keychainAccount) { key = ""; onSaved() }
                    else { error = "השמירה ב-Keychain נכשלה." }
                }
                .disabled(key.isEmpty)
                if let error { Text(error).foregroundStyle(Theme.expense).font(.footnote) }
            } header: { Text("המפתח") } footer: { Text("המפתח נשמר ב-Keychain של האייפון (מוצפן ע״י iOS), לא מוצג שוב ולא נשלח לשום מקום חוץ מ-Anthropic.") }
        }
    }
}

struct AdvisorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onKeyRemoved: () -> Void
    var onConsentRevoked: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                LabeledContent("מודל", value: "Claude Opus 5.5")
                LabeledContent("מחיר", value: "$4 / $20 למיליון טוקנים")
                LabeledContent("מפתח API", value: ClaudeAdvisorService.hasKey ? "שמור ב-Keychain" : "לא הוגדר")
            }
            Section {
                Button("הסרת מפתח ה-API", role: .destructive) { confirmRemove = true }
                Button("ביטול ההסכמה לשליחת נתונים", role: .destructive) {
                    UserDefaults.standard.set(false, forKey: ClaudeAdvisorService.consentKey)
                    onConsentRevoked(); dismiss()
                }
            }
        }
        .navigationTitle("הגדרות יועצת")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סגירה") { dismiss() } } }
        .confirmationDialog("להסיר את המפתח מהאייפון?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("הסרה", role: .destructive) { KeychainStore.delete(ClaudeAdvisorService.keychainAccount); onKeyRemoved(); dismiss() }
        }
    }
}
