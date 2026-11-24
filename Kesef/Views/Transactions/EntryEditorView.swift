import SwiftUI
import SwiftData
import PhotosUI

/// הוספה ועריכה של הכנסה / הוצאה / העברה. מיועד להזנה תוך שניות: סכום ← שם ← קטגוריה ← שמירה.
struct EntryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExpenseTemplate.useCount, order: .reverse) private var templates: [ExpenseTemplate]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var categories: [Category]

    let existing: Entry?
    /// מילוי מראש מההוספה המהירה ("עוד פרטים")
    var prefill: QuickPrefill? = nil
    /// נקרא אחרי שמירה מוצלחת (למשל כדי לסגור גם את חלון ההוספה המהירה)
    var onSaved: (() -> Void)? = nil

    @State private var kind: EntryKind
    @State private var amountText = ""
    @State private var title = ""
    @State private var date = Date.now
    @State private var scope: Scope = .personal
    @State private var categoryID: UUID?
    @State private var subcategoryID: UUID?
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var paymentMethod: PaymentMethod = .creditCard
    @State private var status: EntryStatus = .confirmed
    @State private var certainty: Certainty = .high
    @State private var isFixed = false
    @State private var note = ""
    @State private var receipt: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var makeRecurring = false
    @State private var frequency: Frequency = .monthly
    @State private var installments = 1
    @State private var saveAsTemplate = false
    @State private var error: String?
    @State private var showDelete = false
    @State private var showPartial = false
    @State private var showRefund = false
    @State private var showMore = false

    init(kind: EntryKind = .expense, existing: Entry? = nil, prefill: QuickPrefill? = nil, onSaved: (() -> Void)? = nil) {
        self.existing = existing
        self.prefill = prefill
        self.onSaved = onSaved
        _kind = State(initialValue: existing?.kind ?? kind)
    }

    private var isNew: Bool { existing == nil }
    private var amount: Money? { AmountParser.parse(amountText)?.absolute }
    private var isIncomeLike: Bool { kind == .income || kind == .refund }
    private var canSave: Bool {
        guard let a = amount, a.isPositive else { return false }
        if kind.needsDestinationAccount { return accountID != nil && toAccountID != nil && accountID != toAccountID }
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            if let error { Section { ErrorBanner(message: error) } }

            if isNew && kind == .expense && !templates.isEmpty {
                Section("תבניות") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(templates.prefix(8)) { t in
                                Button { apply(t) } label: {
                                    VStack {
                                        Text(t.title).font(.caption.weight(.semibold))
                                        Text(MoneyFormat.string(t.amount)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Section {
                Picker("סוג", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
                }
                AmountField(text: $amountText, autoFocus: isNew)
                    .padding(.vertical, 6)
                TextField(titlePlaceholder, text: $title)
                    .font(.title3)
                    .submitLabel(.done)
            }

            if kind.isProfitAndLoss {
                Section("סיווג") {
                    ScopePicker(selection: $scope, personalTitle: "אישי", businessTitle: "עסקי")
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    CategoryChips(selection: $categoryID, scope: scope, isIncome: isIncomeLike && kind != .refund)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    SubcategoryPicker(parentID: categoryID, selection: $subcategoryID)
                }
                .onChange(of: scope) { _, newScope in
                    // מחליפים סיווג → מציעים קטגוריות של הסיווג החדש
                    if let c = categories.first(where: { $0.id == categoryID }), c.scope != newScope {
                        categoryID = nil; subcategoryID = nil
                    }
                }
            }

            Section("פרטים") {
                DatePicker("תאריך", selection: $date, displayedComponents: [.date])
                Picker("סטטוס", selection: $status) {
                    ForEach(allowedStatuses) { Text($0.label(for: kind)).tag($0) }
                }
                if kind == .income && status == .planned {
                    Picker("רמת ודאות", selection: $certainty) {
                        ForEach(Certainty.allCases) { Text($0.label).tag($0) }
                    }
                }
                AccountPicker(title: kind.needsDestinationAccount ? "מחשבון" : (isIncomeLike ? "נכנס לחשבון" : "שולם מחשבון / כרטיס"),
                              selection: $accountID)
                if kind.needsDestinationAccount || kind == .partnerPayout {
                    AccountPicker(title: kind == .cardPayment ? "לכרטיס" : "לחשבון", selection: $toAccountID,
                                  allowNone: kind == .partnerPayout)
                }
                if kind == .expense {
                    Picker("אמצעי תשלום", selection: $paymentMethod) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("הוצאה קבועה", isOn: $isFixed)
                }
            }

            if isNew && (kind == .expense || kind == .income) {
                Section {
                    Toggle(kind == .income ? "הכנסה חוזרת" : "הוצאה חוזרת (חיוב קבוע)", isOn: $makeRecurring)
                    if makeRecurring {
                        Picker("תדירות", selection: $frequency) {
                            ForEach(Frequency.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if kind == .income && !makeRecurring {
                        Stepper("פריסה ל-\(installments) תשלומים", value: $installments, in: 1...36)
                        if installments > 1, let a = amount {
                            Text("\(installments) תשלומים חודשיים צפויים, סה״כ \(MoneyFormat.string(a)). הראשון בתאריך שנבחר.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if kind == .expense && !makeRecurring {
                        Toggle("שמור כתבנית לרכישות חוזרות", isOn: $saveAsTemplate)
                    }
                }
            }

            Section("הערה וקבלה") {
                TextField("הערה", text: $note, axis: .vertical)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(receipt == nil ? "צירוף קבלה" : "החלפת קבלה", systemImage: "doc.viewfinder")
                }
                if let receipt, let img = UIImage(data: receipt) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button("הסרת קבלה", role: .destructive) { self.receipt = nil }
                }
            }

            if let e = existing {
                Section("פעולות") {
                    if e.kind == .income && e.status == .planned {
                        Button("סמן כהתקבל היום") { run { try LedgerService(context: context).markReceived(e); dismiss() } }
                        Button("התקבל תשלום חלקי") { showPartial = true }
                    }
                    if e.kind == .expense && e.status == .confirmed {
                        Button("רישום זיכוי / החזר") { showRefund = true }
                    }
                    Button("מחיקה", role: .destructive) { showDelete = true }
                }
                Section {
                    LabeledContent("מקור", value: e.source.label)
                    if let card = e.cardLabel { LabeledContent("כרטיס (מ-Wallet)", value: card) }
                    LabeledContent("נוצר", value: Fmt.dateTime(e.createdAt))
                }
            }
        }
        .navigationTitle(isNew ? (kind == .income ? "הכנסה חדשה" : (kind == .expense ? "הוצאה חדשה" : kind.label)) : "עריכה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("שמירה") { save() }.disabled(!canSave).fontWeight(.semibold)
            }
        }
        .onAppear(perform: load)
        .onChange(of: kind) { _, k in if !allowedStatuses.contains(status) { status = .confirmed }; if k == .income { scope = .business } }
        .onChange(of: photoItem) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self) { receipt = Self.compress(data) } }
        }
        .confirmationDialog("למחוק את התנועה?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("מחיקה לצמיתות", role: .destructive) {
                if let e = existing { run { try LedgerService(context: context).delete(e); dismiss() } }
            }
        } message: { Text("לא ניתן לבטל את המחיקה. אפשר במקום זאת לשנות סטטוס ל'בוטלה'.") }
        .sheet(isPresented: $showPartial) {
            if let e = existing { AmountPromptView(title: "כמה התקבל?", confirmTitle: "רישום") { m, d in
                try LedgerService(context: context).receivePartial(e, received: m, on: d); dismiss()
            } }
        }
        .sheet(isPresented: $showRefund) {
            if let e = existing { AmountPromptView(title: "סכום הזיכוי", confirmTitle: "רישום זיכוי") { m, d in
                try LedgerService(context: context).refund(e, amount: m, date: d); dismiss()
            } }
        }
    }

    private var titlePlaceholder: String {
        switch kind {
        case .income: return "ממי / על מה (למשל: לקוח, אילוף)"
        case .expense: return "בית עסק או תיאור"
        default: return "תיאור"
        }
    }

    private var allowedStatuses: [EntryStatus] {
        switch kind {
        case .income: return [.confirmed, .planned, .cancelled]
        case .expense: return [.confirmed, .planned, .pendingReview, .cancelled]
        default: return [.confirmed, .planned, .cancelled]
        }
    }

    private func load() {
        guard let e = existing, title.isEmpty && amountText.isEmpty else {
            if isNew && kind == .income { scope = .business }
            // הוצאה חדשה מהמסך הראשי — לפי המרחב שפתוח (עסקי / אישי)
            if isNew && kind == .expense && title.isEmpty && amountText.isEmpty && categoryID == nil {
                scope = Scope(rawValue: UserDefaults.standard.string(forKey: "homeSpace") ?? "") ?? .personal
            }
            if isNew, let p = prefill, title.isEmpty && amountText.isEmpty {
                amountText = p.amountText; title = p.title; scope = p.scope; categoryID = p.categoryID
                if let a = p.accountID { accountID = a }
                if let r = p.receipt { receipt = r }
            }
            return
        }
        amountText = MoneyFormat.editString(e.amount)
        title = e.title; date = e.date; scope = e.scope; categoryID = e.categoryID; subcategoryID = e.subcategoryID
        accountID = e.accountID; toAccountID = e.toAccountID; paymentMethod = e.paymentMethod ?? .other
        status = e.status; certainty = e.certainty; isFixed = e.isFixed; note = e.note; receipt = e.receiptImage
    }

    private func apply(_ t: ExpenseTemplate) {
        amountText = MoneyFormat.editString(t.amount); title = t.title; scope = t.scope
        categoryID = t.categoryID
        accountID = t.accountID
        if let pm = t.paymentMethodRaw.flatMap(PaymentMethod.init(rawValue:)) { paymentMethod = pm }
        t.useCount += 1
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let amount, amount.isPositive else { error = "הסכום חייב להיות גדול מאפס."; return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? kind.label : title.trimmingCharacters(in: .whitespaces)
        run {
            if kind == .income && isNew && installments > 1 && !makeRecurring {
                try LedgerService(context: context).createInstallments(total: amount, count: installments, firstDate: date,
                    title: cleanTitle, scope: scope, categoryID: categoryID, accountID: accountID, certainty: certainty, note: note)
                dismiss(); return
            }
            let e = existing ?? Entry(kind: kind, status: status, amount: amount, date: date, title: cleanTitle, scope: scope)
            e.kind = kind; e.amount = amount; e.title = cleanTitle; e.date = date
            e.scope = kind.isProfitAndLoss ? scope : (accounts.first { $0.id == accountID }?.scope ?? .personal)
            e.categoryID = kind.isProfitAndLoss ? categoryID : nil
            e.subcategoryID = kind.isProfitAndLoss ? subcategoryID : nil
            e.accountID = accountID; e.toAccountID = (kind.needsDestinationAccount || kind == .partnerPayout) ? toAccountID : nil
            e.paymentMethod = kind == .expense ? paymentMethod : nil
            if e.status != .confirmed && status == .confirmed { e.confirmedAt = .now }
            e.status = status; e.certainty = certainty; e.isFixed = isFixed; e.note = note; e.receiptImage = receipt
            e.updatedAt = .now
            if existing == nil { context.insert(e) }

            if isNew && makeRecurring {
                let cal = FinanceCalendar.israel
                let rule = RecurringRule(title: cleanTitle, kind: kind, amount: amount, frequency: frequency,
                                         dayOfMonth: cal.day(date), startDate: date, scope: scope)
                rule.categoryID = categoryID; rule.accountID = accountID
                rule.paymentMethod = kind == .expense ? paymentMethod : nil
                context.insert(rule)
                e.recurringRuleID = rule.id
                e.occurrenceDate = cal.startOfDay(date)
                e.isFixed = kind == .expense
            }
            if isNew && saveAsTemplate && kind == .expense {
                context.insert(ExpenseTemplate(title: cleanTitle, amount: amount, scope: scope, categoryID: categoryID,
                                               accountID: accountID, paymentMethod: paymentMethod))
            }
            try context.save()
            Task { await AppLifecycle.refresh() }
            dismiss()
            onSaved?()
        }
    }

    /// הקטנת תמונת קבלה לפני שמירה
    static func compress(_ data: Data) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let r = UIGraphicsImageRenderer(size: size)
        let resized = r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.7) ?? data
    }
}

/// חלון קטן להזנת סכום ותאריך (תשלום חלקי / זיכוי)
struct AmountPromptView: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var confirmTitle: String
    var onConfirm: (Money, Date) throws -> Void
    @State private var text = ""
    @State private var date = Date.now
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error { ErrorBanner(message: error) }
                AmountField(text: $text, autoFocus: true)
                DatePicker("תאריך", selection: $date, displayedComponents: .date)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        guard let m = AmountParser.parse(text)?.absolute, m.isPositive else { error = "הזן סכום תקין."; return }
                        do { try onConfirm(m, date); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
