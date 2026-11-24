import SwiftUI
import SwiftData

/// הכנסה עסקית + קבלה במסך אחד.
/// • morning מחובר (מצב אמיתי): "שמירה והפקת קבלה" — מפיק מסמך רשמי ורושם את ההכנסה מקושרת אליו.
/// • morning לא מחובר: ההכנסה נשמרת ומחכה לקבלה (הכלב מזכיר, ומהרשימה מפיקים בלחיצה כשיתחבר).
/// • awaiting: הפקת קבלה להכנסה שכבר נרשמה — בלי לרשום אותה שוב.
struct BusinessIncomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Client.lastUsedAt, order: .reverse) private var clients: [Client]
    @AppStorage(MorningService.envKey) private var envRaw = MorningService.Environment.demo.rawValue
    @AppStorage(AppSettings.Key.vatRegistered) private var vatRegistered = true

    var awaiting: Entry? = nil
    /// פתיחה ממסך הלקוח — ממלא את פרטיו
    var prefillClientID: UUID? = nil

    @State private var docType: MorningDocType = .taxInvoiceReceipt
    @State private var amountText = ""
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var clientPhone = ""
    @State private var categoryID: UUID?
    @State private var itemDescription = ""
    @State private var payment: MorningPaymentMethod = .bit
    @State private var bankName = ""
    @State private var bankBranch = ""
    @State private var bankAccount = ""
    @State private var chequeNumber = ""
    @State private var reference = ""
    @State private var date = Date.now
    @State private var accountID: UUID?
    @State private var remarks = ""
    @State private var issuedElsewhere = false
    @State private var confirming = false
    @State private var sending = false
    @State private var error: String?
    @State private var created: MorningService.CreatedDocument?
    @State private var savedWithoutReceipt = false
    @State private var showSettings = false
    @State private var loaded = false
    @State private var saveClient = true
    @State private var selectedClientID: UUID?
    @State private var confirmDelete = false

    /// תשלום נכנס (SMS) שעוד לא אושר
    private var isPendingIncome: Bool { awaiting?.status == .pendingReview }

    private var env: MorningService.Environment { MorningService.Environment(rawValue: envRaw) ?? .demo }
    /// הפקה אמיתית אפשרית רק במצב אמיתי עם מפתחות
    private var canIssueReal: Bool { env == .production && MorningService.isConfigured(.production) }
    private var amount: Money? { AmountParser.parse(amountText)?.absolute }
    private var incomeCategories: [Category] { categories.filter { $0.scope == .business && $0.isIncome && !$0.isArchived } }

    private var bankDetails: PaymentBankDetails? {
        guard payment.hasBankDetails else { return nil }
        return PaymentBankDetails(bankName: bankName, bankBranch: bankBranch, bankAccount: bankAccount, chequeNumber: chequeNumber, reference: reference)
    }

    private var draft: MorningDocumentDraft {
        MorningDocumentDraft(type: docType, clientName: clientName, clientEmail: clientEmail, clientPhone: clientPhone,
                             clientTaxId: clients.first { $0.id == selectedClientID }?.taxId,
                             itemDescription: itemDescription.isEmpty ? (incomeCategories.first { $0.id == categoryID }?.name ?? "") : itemDescription,
                             amountIncludingVAT: amount ?? .zero, vatExempt: !vatRegistered,
                             payment: payment, date: date, remarks: remarks, bankDetails: bankDetails)
    }

    var body: some View {
        Group {
            if let created { successView(created) }
            else if savedWithoutReceipt { savedView }
            else { form }
        }
        .kesefScreen()
        .navigationTitle(awaiting == nil ? "הכנסה לעסק" : "הפקת קבלה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("סגירה") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("חיבור morning")
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { MorningSettingsView() } }
        .onAppear(perform: load)
    }

    // MARK: טופס

    private var form: some View {
        Form {
            Section {
                Label(statusText, systemImage: canIssueReal ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                    .foregroundStyle(canIssueReal ? Theme.income : Theme.warning)
                    .font(.subheadline.weight(.semibold))
                if canIssueReal || awaiting != nil {
                    Picker("סוג מסמך", selection: $docType) {
                        ForEach(MorningDocType.allCases.filter(\.recordsPayment)) { Text($0.label).tag($0) }
                    }
                }
            }
            if let error { Section { ErrorBanner(message: error) } }

            Section {
                AmountField(text: $amountText, autoFocus: awaiting == nil)
                if vatRegistered, let a = amount, a.isPositive {
                    let vat = VatEngine.vatIncluded(in: a, rateBasisPoints: AppSettings.vat.rateBasisPoints)
                    Text("כולל מע״מ \(MoneyFormat.string(vat)) · לפני מע״מ \(MoneyFormat.string(a - vat))")
                        .font(.caption).foregroundStyle(Theme.mutedText)
                }
            }

            Section {
                TextField("שם הלקוח", text: $clientName)
                    .onChange(of: clientName) { _, n in
                        if let c = clients.first(where: { $0.id == selectedClientID }), c.name != n { selectedClientID = nil }
                    }
                clientSuggestions
                TextField("מייל — הקבלה תישלח אליו (לא חובה)", text: $clientEmail)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .ltrInput()
                TextField("נייד (לא חובה)", text: $clientPhone).keyboardType(.phonePad).ltrInput()
                Toggle("לשמור את הלקוח לפעם הבאה", isOn: $saveClient)
            } header: { Text("לקוח") }
              footer: { if selectedClientID != nil { Text("הפרטים מולאו מהלקוח השמור — אפשר לשנות.") } }

            Section("שירות") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(incomeCategories) { c in
                            let selected = categoryID == c.id
                            Button {
                                categoryID = selected ? nil : c.id
                                if !selected && (itemDescription.isEmpty || incomeCategories.contains { $0.name == itemDescription }) { itemDescription = c.name }
                            } label: {
                                Label(c.name, systemImage: c.symbol).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(selected ? Theme.onGold : .primary)
                                    .background(selected ? Theme.gold : Theme.surfaceHigh, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                TextField("תיאור בקבלה (למשל: אילוף ביתי — 4 מפגשים)", text: $itemDescription)
            }

            Section {
                Picker("אמצעי תשלום", selection: $payment) {
                    ForEach(MorningPaymentMethod.allCases) { Text($0.label).tag($0) }
                }
                if payment.hasBankDetails {
                    TextField(payment == .cheque ? "בנק המושך" : "בנק", text: $bankName)
                    HStack {
                        TextField("סניף", text: $bankBranch).keyboardType(.numberPad).ltrInput()
                        Divider()
                        TextField("מספר חשבון", text: $bankAccount).keyboardType(.numberPad).ltrInput()
                    }
                    if payment == .cheque {
                        TextField("מספר צ׳ק (חובה)", text: $chequeNumber).keyboardType(.numberPad).ltrInput()
                    }
                    TextField("אסמכתא", text: $reference).keyboardType(.numbersAndPunctuation).ltrInput()
                }
                DatePicker(payment == .cheque ? "תאריך פירעון" : "תאריך", selection: $date, displayedComponents: .date)
                AccountPicker(title: "נכנס לחשבון", selection: $accountID)
            } header: { Text("תשלום") } footer: {
                if payment.hasBankDetails { Text("הפרטים יופיעו על הקבלה. בהעברה בנקאית הם לא חובה.") }
            }

            if (awaiting == nil || isPendingIncome) && !canIssueReal {
                Section {
                    Toggle("כבר הוצאתי קבלה מחוץ לאפליקציה", isOn: $issuedElsewhere)
                }
            }
            if let raw = awaiting?.rawAmountText, awaiting?.source == .incomingPayment {
                Section("ההודעה שהתקבלה") { Text(raw).font(.footnote).foregroundStyle(Theme.mutedText) }
            }
            Section { TextField("הערות בקבלה (לא חובה)", text: $remarks, axis: .vertical) }

            Section {
                Button(action: primaryAction) {
                    HStack {
                        if sending { ProgressView().tint(Theme.onGold) }
                        Text(primaryTitle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.gold)
                .disabled(sending)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if awaiting != nil && !canIssueReal && !isPendingIncome {
                    Button("סימון שהקבלה הופקה ידנית") { markManual() }
                        .frame(maxWidth: .infinity)
                }
                if isPendingIncome {
                    Button("לא הכנסה של העסק — דחייה", role: .destructive) { rejectPending() }
                        .frame(maxWidth: .infinity)
                }
            } footer: { Text(footerText) }

            if let e = awaiting, e.status != .pendingReview {
                Section {
                    Button("מחיקת ההכנסה", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                } footer: { Text("להכנסה שנרשמה בטעות. אם כבר הופקה לה קבלה רשמית — הקבלה עצמה לא נמחקת (מבטלים אותה בחשבונית זיכוי).") }
            }
        }
        .confirmationDialog("למחוק את ההכנסה?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) { deleteAwaiting() }
            Button("ביטול", role: .cancel) {}
        } message: { Text("ההכנסה תימחק מהאפליקציה, כולל מהמע״מ והחלוקה עם השותף. אי אפשר לבטל.") }
        .confirmationDialog("להפיק \(docType.label) רשמי?", isPresented: $confirming, titleVisibility: .visible) {
            Button("הפקה — מסמך רשמי") { issue() }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("\(clientName) · \(MoneyFormat.string(amount ?? .zero)) · \(payment.label)\nמסמך מס רשמי לא ניתן למחיקה — רק ביטול במסמך זיכוי.")
        }
    }

    /// לקוחות שמורים: בלי שם — האחרונים; עם שם — התאמות
    @ViewBuilder private var clientSuggestions: some View {
        let q = clientName.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? Array(clients.prefix(8))
            : Array(clients.filter { $0.name.localizedCaseInsensitiveContains(q) && $0.name != q }.prefix(5))
        if !list.isEmpty && selectedClientID == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(list) { c in
                        Button { apply(c) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.gold)
                                Text(c.name).lineLimit(1)
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.surfaceHigh, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func apply(_ c: Client) {
        selectedClientID = c.id
        clientName = c.name
        clientEmail = c.email
        clientPhone = c.phone
        bankName = c.bankName; bankBranch = c.bankBranch; bankAccount = c.bankAccount
        if let p = c.preferredPayment { payment = p }
        if let cat = c.defaultCategoryID, incomeCategories.contains(where: { $0.id == cat }) { categoryID = cat }
        if !c.defaultDescription.isEmpty { itemDescription = c.defaultDescription }
        if amountText.isEmpty && c.lastAmount.isPositive { amountText = MoneyFormat.editString(c.lastAmount) }
    }

    /// שמירה/עדכון של הלקוח אחרי הכנסה (לפי שם)
    private func rememberClient(amount: Money) {
        let name = clientName.trimmingCharacters(in: .whitespaces)
        guard saveClient, !name.isEmpty else { return }
        let c = clients.first { $0.id == selectedClientID } ?? clients.first { $0.name == name } ?? {
            let n = Client(name: name); context.insert(n); return n
        }()
        c.name = name
        c.email = clientEmail.trimmingCharacters(in: .whitespaces)
        c.phone = clientPhone.trimmingCharacters(in: .whitespaces)
        if payment.hasBankDetails && (!bankName.isEmpty || !bankAccount.isEmpty) {
            c.bankName = bankName; c.bankBranch = bankBranch; c.bankAccount = bankAccount
        }
        c.preferredPayment = payment
        c.defaultCategoryID = categoryID
        c.defaultDescription = itemDescription.trimmingCharacters(in: .whitespaces)
        c.lastAmountMinor = amount.minorUnits
        c.useCount += 1
        c.lastUsedAt = .now
    }

    private var statusText: String {
        if canIssueReal { return "morning מחובר — תופק קבלה רשמית" }
        if isPendingIncome { return "תשלום נכנס — בדוק את הפרטים ואשר" }
        return awaiting == nil ? "morning עוד לא מחובר — ההכנסה תישמר ותחכה לקבלה" : "morning עוד לא מחובר — אי אפשר להפיק עכשיו"
    }

    private var primaryTitle: String {
        if sending { return "מפיק…" }
        if canIssueReal { return awaiting == nil ? "שמירה והפקת קבלה" : (isPendingIncome ? "אישור והפקת קבלה" : "הפקת קבלה") }
        if isPendingIncome { return "אישור ההכנסה" }
        return awaiting == nil ? "שמירת ההכנסה" : "חיבור morning"
    }

    private var footerText: String {
        if canIssueReal { return "הקבלה מופקת ב-morning, נשלחת ללקוח במייל אם הוזן, וההכנסה נרשמת כאן מקושרת אליה — כולל מע״מ וחלוקה עם השותף." }
        if issuedElsewhere { return "ההכנסה תירשם כמכוסה בקבלה." }
        return "ההכנסה נרשמת עכשיו (כולל מע״מ וחלוקה עם השותף) ומופיעה ב״מחכות לקבלה״. כשתחבר את morning — מפיקים משם בלחיצה."
    }

    // MARK: מסכי סיום

    private func successView(_ doc: MorningService.CreatedDocument) -> some View {
        VStack(spacing: 16) {
            DogCompanionView(mood: .proud, size: 80)
            Text("\(docType.label) מס׳ \(doc.number) הופק").font(.title2.bold()).multilineTextAlignment(.center)
            Text("ההכנסה רשומה ומקושרת לקבלה.").foregroundStyle(Theme.mutedText)
            if doc.taxAuthorityError != 0 {
                Label("רשות המסים החזירה שגיאה (\(doc.taxAuthorityError)) על מספר ההקצאה. בדוק את המסמך ב-morning.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning).font(.footnote)
            }
            if let url = doc.url {
                ShareLink(item: url) { Label("שליחה ללקוח (וואטסאפ / מייל)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(.gold)
                Link(destination: url) { Label("פתיחת המסמך", systemImage: "doc.richtext") }
            }
            Button("סיום") { dismiss() }.padding(.top)
        }
        .padding()
    }

    private var savedView: some View {
        VStack(spacing: 16) {
            DogCompanionView(mood: .happy, size: 80)
            Text("ההכנסה נשמרה").font(.title2.bold())
            Text(issuedElsewhere ? "סומנה כמכוסה בקבלה." : "היא מחכה לקבלה. ברגע ש-morning יחובר, תפיק אותה בלחיצה מ״קבלות ודוחות״.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.mutedText)
            Button("סיום") { dismiss() }.buttonStyle(.gold).padding(.top)
        }
        .padding()
    }

    // MARK: פעולות

    private func load() {
        guard !loaded else { return }
        loaded = true
        if !vatRegistered { docType = .receipt }
        if accountID == nil { accountID = accounts.first { $0.kind == .businessBank }?.id }
        if let id = prefillClientID, let c = clients.first(where: { $0.id == id }) { apply(c) }
        guard let e = awaiting else { return }
        amountText = MoneyFormat.editString(e.amount)
        date = e.date
        categoryID = e.categoryID
        accountID = e.accountID ?? accountID
        let parts = e.title.components(separatedBy: " — ")
        if parts.count >= 2 { clientName = parts[0]; itemDescription = parts.dropFirst().joined(separator: " — ") }
        else if e.source != .incomingPayment { itemDescription = e.title }
        for line in e.note.components(separatedBy: "\n") {
            if line.hasPrefix("לקוח: ") { clientName = String(line.dropFirst(6)) }
            if line.hasPrefix("מייל: ") { clientEmail = String(line.dropFirst(6)) }
            if line.hasPrefix("נייד: ") { clientPhone = String(line.dropFirst(6)) }
        }
        // תשלום נכנס: אם המשלם הוא לקוח שמור — ממלאים את פרטיו
        if e.source == .incomingPayment, !clientName.isEmpty,
           let c = clients.first(where: { $0.name == clientName || $0.name.contains(clientName) || clientName.contains($0.name) }) {
            let keepAmount = amountText
            apply(c)
            if !keepAmount.isEmpty && keepAmount != "0" { amountText = keepAmount }
        }
        switch e.paymentMethod {
        case .cash: payment = .cash
        case .bankTransfer: payment = .bankTransfer
        case .check: payment = .cheque
        case .creditCard: payment = .creditCard
        case .applePay: payment = .applePay
        case .bit: payment = .bit
        default: break
        }
    }

    private func primaryAction() {
        error = nil
        guard let a = amount, a.isPositive else { error = "הזן סכום גדול מאפס."; return }
        if canIssueReal {
            do { try draft.validate(); confirming = true } catch { self.error = message(for: error) }
            return
        }
        if isPendingIncome { confirmPending(amount: a); return }
        if awaiting != nil { showSettings = true; return }
        saveIncome(amount: a)
    }

    private func message(for error: Error) -> String {
        switch error as? MorningDocumentDraft.ValidationError {
        case .missingClient: return "חסר שם לקוח."
        case .missingDescription: return "בחר שירות או כתוב תיאור לקבלה."
        case .invalidAmount: return "הזן סכום גדול מאפס."
        case .invalidEmail: return "כתובת המייל לא תקינה."
        case .missingChequeNumber: return "בצ׳ק צריך מספר צ׳ק."
        case nil: return error.localizedDescription
        }
    }

    /// שמירת הכנסה בלי הפקה (morning לא מחובר)
    private func saveIncome(amount: Money) {
        let desc = draft.itemDescription.trimmingCharacters(in: .whitespaces)
        let client = clientName.trimmingCharacters(in: .whitespaces)
        let title = client.isEmpty ? (desc.isEmpty ? "הכנסה" : desc) : (desc.isEmpty ? client : "\(client) — \(desc)")
        let e = Entry(kind: .income, status: .confirmed, amount: amount, date: date, title: title, scope: .business,
                      categoryID: categoryID, accountID: accountID, source: .manual)
        e.paymentMethod = payment.ledgerMethod
        e.confirmedAt = .now
        e.note = noteLines().joined(separator: "\n")
        if issuedElsewhere { e.externalRef = IncomeReceipts.manualRef }
        context.insert(e)
        rememberClient(amount: amount)
        do {
            try context.save()
            savedWithoutReceipt = true
            Task { await AppLifecycle.refresh() }
        } catch { self.error = "השמירה נכשלה: \(error.localizedDescription)" }
    }

    private func noteLines() -> [String] {
        var lines: [String] = []
        if !clientName.isEmpty { lines.append("לקוח: \(clientName)") }
        if !clientEmail.isEmpty { lines.append("מייל: \(clientEmail)") }
        if !clientPhone.isEmpty { lines.append("נייד: \(clientPhone)") }
        if payment == .cheque && !chequeNumber.isEmpty { lines.append("צ׳ק מס׳ \(chequeNumber) · בנק \(bankName) \(bankBranch)/\(bankAccount)") }
        if payment.hasBankDetails && !reference.isEmpty { lines.append("אסמכתא: \(reference)") }
        if !remarks.isEmpty { lines.append(remarks) }
        return lines
    }

    /// מעדכן הכנסה קיימת לפי הטופס ומאשר אותה
    private func applyForm(to e: Entry, amount: Money) {
        let desc = draft.itemDescription.trimmingCharacters(in: .whitespaces)
        let client = clientName.trimmingCharacters(in: .whitespaces)
        e.amount = amount
        e.title = client.isEmpty ? (desc.isEmpty ? "הכנסה" : desc) : (desc.isEmpty ? client : "\(client) — \(desc)")
        e.categoryID = categoryID
        e.accountID = accountID
        e.date = date
        e.paymentMethod = payment.ledgerMethod
        let message = e.source == .incomingPayment ? (e.rawAmountText.map { ["הודעה: " + $0] } ?? []) : []
        e.note = (noteLines() + message).joined(separator: "\n")
        if e.status != .confirmed { e.status = .confirmed; e.confirmedAt = .now }
        e.updatedAt = .now
    }

    private func confirmPending(amount: Money) {
        guard let e = awaiting else { return }
        applyForm(to: e, amount: amount)
        if issuedElsewhere { e.externalRef = IncomeReceipts.manualRef }
        rememberClient(amount: amount)
        do {
            try context.save()
            NotificationService.removePendingNotification(entryID: e.id)
            savedWithoutReceipt = true
            Task { await AppLifecycle.refresh() }
        } catch { self.error = "השמירה נכשלה: \(error.localizedDescription)" }
    }

    private func rejectPending() {
        guard let e = awaiting else { return }
        e.status = .cancelled
        e.updatedAt = .now
        try? context.save()
        NotificationService.removePendingNotification(entryID: e.id)
        Task { await AppLifecycle.refresh() }
        dismiss()
    }

    private func deleteAwaiting() {
        guard let e = awaiting else { return }
        do {
            try LedgerService(context: context).delete(e)
            Task { await AppLifecycle.refresh() }
            dismiss()
        } catch { self.error = "המחיקה נכשלה: \(error.localizedDescription)" }
    }

    private func markManual() {
        guard let e = awaiting else { return }
        e.externalRef = IncomeReceipts.manualRef
        e.updatedAt = .now
        try? context.save()
        dismiss()
    }

    private func issue() {
        sending = true
        let d = draft
        Task {
            do {
                let doc = try await MorningService.createDocument(d)
                let entry: Entry?
                if let e = awaiting {
                    // הכנסה שכבר רשומה — רק מקשרים אליה את המסמך (לא נרשמת פעמיים)
                    if e.status == .pendingReview { applyForm(to: e, amount: d.amountIncludingVAT) }
                    e.externalRef = "morning:\(doc.id)"
                    e.note = (["\(d.type.label) מס׳ \(doc.number)"] + (doc.url.map { [$0.absoluteString] } ?? []) + [e.note])
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    e.updatedAt = .now
                    entry = e
                } else {
                    entry = try MorningService.recordIncome(context: context, draft: d, doc: doc, categoryID: categoryID, accountID: accountID)
                }
                let vat = (vatRegistered && !d.vatExempt) ? VatEngine.vatIncluded(in: d.amountIncludingVAT, rateBasisPoints: AppSettings.vat.rateBasisPoints) : .zero
                let saved = IssuedDocument(externalID: doc.id, number: doc.number, type: d.type, clientName: d.clientName,
                                           clientEmail: d.clientEmail ?? "", itemDescription: d.itemDescription,
                                           amount: d.amountIncludingVAT, vat: vat, payment: d.payment, date: d.date,
                                           url: doc.url, environment: env.rawValue)
                saved.entryID = entry?.id
                context.insert(saved)
                rememberClient(amount: d.amountIncludingVAT)
                try context.save()
                created = doc
                Task { await AppLifecycle.refresh() }
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// רשימת הכנסות עסקיות שמחכות לקבלה
struct AwaitingReceiptsSection: View {
    var entries: [Entry]
    @Environment(\.modelContext) private var context
    @State private var issuing: Entry?
    @State private var deleting: Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("מחכות לקבלה", systemImage: "clock.badge.exclamationmark").font(.headline).foregroundStyle(Theme.warning)
                Spacer()
                Text("\(entries.count)").font(.headline).monospacedDigit()
            }
            ForEach(entries) { e in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).lineLimit(1)
                        Text(Fmt.date(e.date)).font(.caption).foregroundStyle(Theme.mutedText)
                    }
                    Spacer()
                    MoneyText(money: e.amount, font: .subheadline.weight(.semibold))
                    Button("הפקה") { issuing = e }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Theme.gold)
                }
                .contextMenu {
                    Button("סימון שהקבלה הופקה ידנית", systemImage: "checkmark") {
                        e.externalRef = IncomeReceipts.manualRef
                        try? context.save()
                    }
                    Button("מחיקת ההכנסה (נרשמה בטעות)", systemImage: "trash", role: .destructive) { deleting = e }
                }
            }
            Text("לחיצה ארוכה על הכנסה — סימון שהקבלה הופקה מחוץ לאפליקציה, או מחיקה אם נרשמה בטעות.").font(.caption2).foregroundStyle(Theme.mutedText)
        }
        .card()
        .sheet(item: $issuing) { e in NavigationStack { BusinessIncomeView(awaiting: e) } }
        .confirmationDialog("למחוק את ההכנסה?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {
                if let e = deleting { try? LedgerService(context: context).delete(e) }
                deleting = nil
            }
        } message: { Text("אי אפשר לבטל.") }
    }
}
