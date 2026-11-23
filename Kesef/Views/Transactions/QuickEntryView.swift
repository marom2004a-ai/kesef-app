import SwiftUI
import SwiftData

/// נתונים שעוברים מההוספה המהירה למסך המלא
struct QuickPrefill {
    var amountText: String
    var title: String
    var scope: Scope
    var categoryID: UUID?
    var accountID: UUID?
}

/// הוספה מהירה: מקלדת מספרים גדולה → קטגוריה → שמירה. שתי לחיצות.
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
    @State private var showFull = false
    @State private var error: String?
    @State private var saved = 0
    @State private var shake = 0

    init(kind: EntryKind) {
        self.kind = kind
        let home = Scope(rawValue: UserDefaults.standard.string(forKey: "homeSpace") ?? "") ?? .business
        _scope = State(initialValue: kind == .income ? .business : home)
    }

    private var amount: Money? { AmountParser.parse(amountText)?.absolute }
    private var isIncome: Bool { kind == .income }

    /// קטגוריות של הסיווג, הנפוצות ביותר קודם (לפי 60 התנועות האחרונות)
    private var chips: [Category] {
        let list = categories.filter { $0.scope == scope && $0.isIncome == isIncome && !$0.isArchived && $0.parentID == nil }
        var use: [UUID: Int] = [:]
        for e in recent.prefix(60) { if let c = e.categoryID { use[c, default: 0] += 1 } }
        return list.sorted { (use[$0.id] ?? 0, -$0.sortOrder) > (use[$1.id] ?? 0, -$1.sortOrder) }
    }

    private var lastAccountKey: String { "quickAccount-\(scope.rawValue)-\(kind.rawValue)" }

    var body: some View {
        VStack(spacing: 14) {
            Picker("סיווג", selection: $scope) {
                Text("🐾 עסקי").tag(Scope.business)
                Text("👤 אישי").tag(Scope.personal)
            }
            .pickerStyle(.segmented)

            amountDisplay

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
        .navigationTitle(isIncome ? "הכנסה חדשה" : "הוצאה חדשה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button("עוד פרטים") { showFull = true } }
        }
        .navigationDestination(isPresented: $showFull) {
            EntryEditorView(kind: kind, prefill: QuickPrefill(amountText: amountText, title: title, scope: scope,
                                                              categoryID: categoryID, accountID: accountID)) { dismiss() }
        }
        .onAppear(perform: restoreAccount)
        .onChange(of: scope) { _, _ in
            if let c = categories.first(where: { $0.id == categoryID }), c.scope != scope { categoryID = nil }
            restoreAccount()
        }
        .sensoryFeedback(.success, trigger: saved)
        .sensoryFeedback(.error, trigger: shake)
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
        if let raw = UserDefaults.standard.string(forKey: lastAccountKey), let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id && !$0.isArchived }) {
            accountID = id
        } else if accountID == nil || accounts.first(where: { $0.id == accountID })?.scope != scope {
            accountID = accounts.first { !$0.isArchived && $0.scope == scope }?.id
        }
    }

    private func save() {
        guard let amount, amount.isPositive else { shake += 1; return }
        let cat = categories.first { $0.id == categoryID }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let e = Entry(kind: kind, status: .confirmed, amount: amount, date: .now,
                      title: cleanTitle.isEmpty ? (cat?.name ?? kind.label) : cleanTitle, scope: scope)
        e.categoryID = categoryID
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
