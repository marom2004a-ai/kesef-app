import SwiftUI
import SwiftData

/// נתונים שעוברים מההוספה המהירה למסך המלא
struct QuickPrefill {
    var amountText: String
    var title: String
    var scope: Scope
    var categoryID: UUID?
    var accountID: UUID?
    var receipt: Data? = nil
}

/// הוספה מהירה: מקלדת מספרים גדולה → קטגוריה → שמירה. שתי לחיצות.
/// הכנסה כאן היא תמיד "הכנסה מהעסק" לצד האישי (משיכה מחשבון העסק) — בלי פירוט על מה.
/// הכנסה עסקית נרשמת במסך המשולב עם הקבלה (BusinessIncomeView).
struct QuickEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Entry.createdAt, order: .reverse) private var recent: [Entry]

    let kind: EntryKind
    @State private var amountText = ""
    @State private var title = ""
    @State private var scope: Scope
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var fromAccountID: UUID?
    @State private var receipt: Data?
    @State private var showFull = false
    @State private var error: String?
    @State private var saved = 0
    @State private var shake = 0

    init(kind: EntryKind) {
        self.kind = kind
        let home = Scope(rawValue: UserDefaults.standard.string(forKey: "homeSpace") ?? "") ?? .business
        _scope = State(initialValue: kind == .income ? .personal : home)
    }

    /// "הכנסה מהעסק" — משיכה מחשבון העסק לאישי
    private var isDraw: Bool { kind == .income }
    @AppStorage(AppSettings.Key.partnerShareBP) private var partnerBP = 0

    /// הצעה: החלק שלי מרווח החודש הקודם, פחות מה שכבר הועבר אליי החודש
    private var drawSuggestion: DrawSuggestion {
        OwnerDrawPlanner.suggestion(entries: recent.map(\.snapshot), now: .now, vat: AppSettings.vat,
                                    deductibleBP: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.vatDeductibleBP) }),
                                    partnerShareBP: partnerBP)
    }

    private var amount: Money? { AmountParser.parse(amountText)?.absolute }
    private var isIncome: Bool { kind == .income }

    /// קטגוריות של הסיווג, הנפוצות ביותר קודם (לפי 60 התנועות האחרונות)
    private var chips: [Category] {
        let wantIncome = isIncome
        let list = categories.filter { $0.scope == scope && $0.isIncome == wantIncome && !$0.isArchived && $0.parentID == nil }
        var use: [UUID: Int] = [:]
        for e in recent.prefix(60) { if let c = e.categoryID { use[c, default: 0] += 1 } }
        return list.sorted { a, b in
            let ua = use[a.id] ?? 0, ub = use[b.id] ?? 0
            return ua != ub ? ua > ub : a.sortOrder < b.sortOrder
        }
    }

    private var lastAccountKey: String { "quickAccount-\(scope.rawValue)-\(kind.rawValue)" }

    var body: some View {
        VStack(spacing: 14) {
            if !isDraw {
                Picker("סיווג", selection: $scope) {
                    Text("🐾 עסקי").tag(Scope.business)
                    Text("👤 אישי").tag(Scope.personal)
                }
                .pickerStyle(.segmented)
            }

            amountDisplay

            if isDraw { drawSection } else { expenseSection }

            if let error { Text(error).font(.footnote).foregroundStyle(Theme.expense) }

            Spacer(minLength: 0)
            NumberPad(text: $amountText)

            Button(action: save) {
                Text(isIncome ? "שמירת הכנסה" : "שמירת הוצאה").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.gold)
            .disabled(!(amount?.isPositive ?? false))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(isDraw ? "הכנסה מהעסק" : "הוצאה חדשה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            if !isDraw { ToolbarItem(placement: .primaryAction) { Button("עוד פרטים") { showFull = true } } }
        }
        .navigationDestination(isPresented: $showFull) {
            EntryEditorView(kind: kind, prefill: QuickPrefill(amountText: amountText, title: title, scope: scope,
                                                              categoryID: categoryID, accountID: accountID,
                                                              receipt: receipt)) { dismiss() }
        }
        .onAppear(perform: restoreAccount)
        .onChange(of: scope) { _, _ in
            if let c = categories.first(where: { $0.id == categoryID }), c.scope != scope { categoryID = nil }
            restoreAccount()
        }
        .sensoryFeedback(.success, trigger: saved)
        .sensoryFeedback(.error, trigger: shake)
    }

    private var drawSection: some View {
        let s = drawSuggestion
        return VStack(spacing: 10) {
            if s.myShare.isPositive {
                Button {
                    amountText = MoneyFormat.editString(s.remaining.isPositive ? s.remaining : s.myShare)
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars").foregroundStyle(Theme.gold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("החלק שלך מהרווח של \(Fmt.monthYear(s.profitMonth)): \(MoneyFormat.string(s.myShare))")
                                .font(.subheadline.weight(.semibold))
                            Text(s.drawnThisMonth.isPositive ? "כבר הועבר החודש \(MoneyFormat.string(s.drawnThisMonth)) · לחץ למילוי היתרה" : "לחץ למילוי הסכום")
                                .font(.caption).foregroundStyle(Theme.mutedText)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                accountMenu("מחשבון העסק", selection: $fromAccountID, scope: .business)
                Image(systemName: "arrow.left").foregroundStyle(Theme.mutedText)
                accountMenu("לחשבון האישי", selection: $accountID, scope: .personal)
            }
            Text("נרשם באישי כ״הכנסה מהעסק״ — בלי פירוט, ולא משנה את רווח העסק.")
                .font(.caption2).foregroundStyle(Theme.mutedText)
        }
    }

    private func accountMenu(_ title: String, selection: Binding<UUID?>, scope: Scope) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.mutedText)
            Picker(title, selection: selection) {
                Text("לא נבחר").tag(UUID?.none)
                ForEach(accounts.filter { !$0.isArchived && $0.scope == scope }) { a in Text(a.name).tag(Optional(a.id)) }
            }
            .pickerStyle(.menu).labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var expenseSection: some View {
        VStack(spacing: 14) {
            if scope == .business {
                ReceiptCaptureButton(receipt: $receipt)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { c in
                        let selected = categoryID == c.id
                        Button {
                            withAnimation(.snappy) { categoryID = selected ? nil : c.id }
                        } label: {
                            Label(c.name, systemImage: c.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .foregroundStyle(selected ? Theme.onGold : .primary)
                                .background(selected ? Theme.gold : Theme.surfaceHigh, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            .sensoryFeedback(.selection, trigger: categoryID)

            HStack(spacing: 10) {
                TextField(isIncome ? "ממי? (לא חובה)" : "על מה? (לא חובה)", text: $title)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Picker("חשבון", selection: $accountID) {
                    Text("בלי חשבון").tag(UUID?.none)
                    ForEach(accounts.filter { !$0.isArchived }) { a in
                        Label(a.name, systemImage: a.kind.symbol).tag(Optional(a.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 140)
            }
        }
    }

    private var amountDisplay: some View {
        let shown = amountText.isEmpty ? "0" : amountText
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(shown)
                .font(.system(size: 58, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(amountText.isEmpty ? Theme.mutedText : (isIncome ? Theme.income : Theme.goldBright))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.5)
            Text("₪").font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(Theme.mutedText)
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .animation(.snappy(duration: 0.18), value: amountText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("סכום \(shown) שקלים")
    }

    private func restoreAccount() {
        if isDraw {
            if fromAccountID == nil { fromAccountID = accounts.first { !$0.isArchived && $0.scope == .business && $0.kind == .businessBank }?.id
                ?? accounts.first { !$0.isArchived && $0.scope == .business }?.id }
            if accountID == nil { accountID = accounts.first { !$0.isArchived && $0.scope == .personal && $0.kind == .bank }?.id
                ?? accounts.first { !$0.isArchived && $0.scope == .personal }?.id }
            return
        }
        if let raw = UserDefaults.standard.string(forKey: lastAccountKey), let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id && !$0.isArchived }) {
            accountID = id
        } else if accountID == nil || accounts.first(where: { $0.id == accountID })?.scope != scope {
            accountID = accounts.first { !$0.isArchived && $0.scope == scope }?.id
        }
    }

    private func save() {
        guard let amount, amount.isPositive else { shake += 1; return }
        if isDraw {
            let e = Entry(kind: .ownerDraw, status: .confirmed, amount: amount, date: .now, title: "הכנסה מהעסק", scope: .personal)
            e.accountID = fromAccountID
            e.toAccountID = accountID
            e.confirmedAt = .now
            context.insert(e)
            do {
                try context.save()
                saved += 1
                Task { await AppLifecycle.refresh() }
                dismiss()
            } catch { self.error = "השמירה נכשלה: \(error.localizedDescription)" }
            return
        }
        let cat = categories.first { $0.id == categoryID }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let e = Entry(kind: kind, status: .confirmed, amount: amount, date: .now,
                      title: cleanTitle.isEmpty ? (cat?.name ?? kind.label) : cleanTitle, scope: scope)
        e.categoryID = categoryID
        if scope == .business, let receipt { e.receiptImage = receipt }
        e.accountID = accountID
        if kind == .expense {
            e.paymentMethod = accounts.first { $0.id == accountID }?.kind == .cash ? .cash : .creditCard
        }
        e.confirmedAt = .now
        context.insert(e)
        do {
            try context.save()
            if let accountID { UserDefaults.standard.set(accountID.uuidString, forKey: lastAccountKey) }
            saved += 1
            Task { await AppLifecycle.refresh() }
            dismiss()
        } catch {
            self.error = "השמירה נכשלה: \(error.localizedDescription)"
        }
    }
}

/// מקלדת מספרים גדולה. בונה טקסט סכום עם עד 2 ספרות אחרי הנקודה.
struct NumberPad: View {
    @Binding var text: String
    @State private var taps = 0

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(keys, id: \.self) { k in
                Button { press(k) } label: {
                    Group {
                        if k == "⌫" { Image(systemName: "delete.left") } else { Text(k) }
                    }
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(PadKeyStyle())
                .accessibilityLabel(k == "⌫" ? "מחיקה" : (k == "." ? "נקודה" : k))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private func press(_ k: String) {
        taps += 1
        switch k {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case ".":
            if !text.contains(".") { text = text.isEmpty ? "0." : text + "." }
        default:
            if let dot = text.firstIndex(of: ".") {
                guard text[text.index(after: dot)...].count < 2 else { return }
            } else {
                guard text.count < 7 else { return }
                if text == "0" { text = "" }
            }
            text += k
        }
    }
}

private struct PadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
