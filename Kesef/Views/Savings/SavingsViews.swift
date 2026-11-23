import SwiftUI
import SwiftData
import Charts

/// יועץ חיסכון + יעדים + ניתוח הכנסות של עצמאי
struct SavingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @Query private var rules: [RecurringRule]
    @Query private var categories: [Category]
    @Query private var accounts: [Account]
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @State private var editingGoal: SavingsGoal?
    @State private var creatingGoal = false
    @State private var depositGoal: SavingsGoal?

    var body: some View {
        let snaps = entries.map(\.snapshot)
        let recs = SavingsAdvisor.recommendations(AdvisorInput(now: .now, entries: snaps, recurring: rules.map(\.snapshot),
                                                               categories: categories.map(\.snapshot), accounts: accounts.map(\.snapshot)))
        let analysis = IncomeAnalyzer.analyze(entries: snaps, recurring: rules.map(\.snapshot), now: .now)
        List {
            Section("הכנסות משתנות — תמונת מצב") {
                incomeSummary(analysis)
            }
            Section("המלצות") {
                ForEach(recs) { r in RecommendationRow(rec: r) }
                Text("ההמלצות מחושבות במכשיר לפי כללים קבועים ומבוססות רק על הנתונים שלך. הן אינן תחליף לייעוץ פיננסי או חשבונאי מוסמך.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                if goals.isEmpty {
                    EmptyStateView(symbol: "target", title: "אין יעדי חיסכון", message: "הגדר יעד — קרן חירום, רכב, חופשה — ועקוב אחרי ההתקדמות.",
                                   actionTitle: "יעד חדש") { creatingGoal = true }
                        .listRowBackground(Color.clear)
                }
                ForEach(goals) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(g.title).font(.headline)
                            Spacer()
                            Button("הפקדה") { depositGoal = g }.buttonStyle(.bordered).font(.caption)
                        }
                        ProgressView(value: Double(min(Money.ratioBasisPoints(g.saved, of: g.target) ?? 0, 10_000)), total: 10_000)
                        HStack {
                            Text("\(MoneyFormat.string(g.saved)) מתוך \(MoneyFormat.string(g.target))")
                            Spacer()
                            if let d = g.targetDate { Text("יעד: \(Fmt.date(d))") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let need = monthlyNeeded(g) {
                            Text("כדי להגיע ליעד בזמן: \(MoneyFormat.string(need)) בחודש").font(.caption2).foregroundStyle(Theme.forecast)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingGoal = g }
                    .swipeActions { Button("מחיקה", role: .destructive) { context.delete(g); try? context.save() } }
                }
            } header: {
                HStack { Text("יעדי חיסכון"); Spacer(); Button("הוספה") { creatingGoal = true }.font(.caption) }
            }
        }
        .navigationTitle("חיסכון ויעדים")
        .sheet(item: $editingGoal) { g in NavigationStack { GoalEditorView(goal: g) } }
        .sheet(isPresented: $creatingGoal) { NavigationStack { GoalEditorView(goal: nil) } }
        .sheet(item: $depositGoal) { g in
            AmountPromptView(title: "הפקדה ל\(g.title)", confirmTitle: "הוספה") { m, d in
                g.saved = g.saved + m
                if let acc = g.accountID {
                    // הפקדה בפועל = העברה לחשבון החיסכון (לא הוצאה)
                    let from = accounts.first { $0.kind.isLiquid && !$0.isArchived }?.id
                    let t = Entry(kind: .transfer, status: .confirmed, amount: m, date: d, title: "הפקדה: \(g.title)", scope: .personal, accountID: from)
                    t.toAccountID = acc
                    context.insert(t)
                }
                try context.save()
            }
        }
    }

    @ViewBuilder
    private func incomeSummary(_ a: IncomeAnalysis) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                avg("ממוצע 3 ח׳", a.average3, need: 3, have: a.completeMonthsWithData)
                avg("ממוצע 6 ח׳", a.average6, need: 6, have: a.completeMonthsWithData)
                avg("ממוצע 12 ח׳", a.average12, need: 12, have: a.completeMonthsWithData)
            }
        }
        if !a.months.isEmpty {
            Chart(a.months) { m in
                BarMark(x: .value("חודש", Fmt.shortMonth(m.monthStart)), y: .value("הכנסה", NSDecimalNumber(decimal: m.income.decimalValue).doubleValue))
                    .foregroundStyle(by: .value("סוג חודש", m.strength?.label ?? (m.isComplete ? "רגיל" : "חודש נוכחי / חלקי")))
            }
            .chartForegroundStyleScale(["חודש חלש": Theme.expense, "חודש רגיל": Theme.accent, "חודש חזק": Theme.income,
                                        "רגיל": Theme.accent, "חודש נוכחי / חלקי": Color.gray])
            .frame(height: 180)
        }
        LabeledContent("חיובים קבועים בחודש") { MoneyText(money: a.fixedMonthly) }
        if let bp = a.fixedToIncomeBasisPoints {
            LabeledContent("קבועות מתוך ההכנסה הממוצעת") { Text(Fmt.percent(bp)).foregroundStyle(bp > 6000 ? Theme.expense : .primary) }
        }
        if let w = a.weakest, let s = a.strongest {
            Text("החודש החלש: \(Fmt.monthYear(w.monthStart)) (\(MoneyFormat.string(w.income))). החזק: \(Fmt.monthYear(s.monthStart)) (\(MoneyFormat.string(s.income))).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func avg(_ title: String, _ m: Money?, need: Int, have: Int) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let m { MoneyText(money: m, font: .subheadline.weight(.semibold)) }
            else { Text("עוד \(need - have) ח׳").font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func monthlyNeeded(_ g: SavingsGoal) -> Money? {
        guard let d = g.targetDate, g.saved < g.target else { return nil }
        let cal = FinanceCalendar.israel
        let months = max(1, (cal.calendar.dateComponents([.month], from: .now, to: d).month ?? 0) + 1)
        return Money(minorUnits: Money.roundedDivide((g.target - g.saved).minorUnits, by: Int64(months)))
    }
}

struct RecommendationRow: View {
    let rec: Recommendation
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: rec.severity == .warning ? "exclamationmark.triangle.fill" : (rec.severity == .suggestion ? "lightbulb.fill" : "info.circle.fill"))
                    .foregroundStyle(rec.severity == .warning ? Theme.expense : (rec.severity == .suggestion ? Theme.warning : Theme.forecast))
                Text(rec.title).font(.headline)
                Spacer()
                if let p = rec.monthlyPotential { MoneyText(money: p, font: .caption.weight(.semibold)) }
            }
            Text(rec.detail).font(.subheadline)
            Button(expanded ? "הסתר מקור" : "על מה זה מבוסס?") { withAnimation { expanded.toggle() } }.font(.caption)
            if expanded { Text(rec.basis).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}

struct GoalEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal?
    @State private var title = ""
    @State private var targetText = ""
    @State private var savedText = ""
    @State private var hasDate = false
    @State private var date = FinanceCalendar.israel.addMonths(12, to: .now)
    @State private var accountID: UUID?

    var body: some View {
        Form {
            TextField("שם היעד", text: $title)
            Section("סכום יעד") { AmountField(text: $targetText) }
            Section("נחסך עד כה") { TextField("0", text: $savedText).keyboardType(.decimalPad) }
            Toggle("תאריך יעד", isOn: $hasDate)
            if hasDate { DatePicker("עד", selection: $date, displayedComponents: .date) }
            AccountPicker(title: "חשבון חיסכון (לא חובה)", selection: $accountID)
        }
        .navigationTitle(goal == nil ? "יעד חדש" : "עריכת יעד")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("שמירה") {
                    guard let t = AmountParser.parse(targetText)?.absolute, t.isPositive else { return }
                    let g = goal ?? SavingsGoal(title: title, target: t)
                    g.title = title; g.target = t; g.saved = AmountParser.parse(savedText)?.absolute ?? .zero
                    g.targetDate = hasDate ? date : nil; g.accountID = accountID
                    if goal == nil { context.insert(g) }
                    try? context.save(); dismiss()
                }.disabled(title.isEmpty || AmountParser.parse(targetText) == nil)
            }
        }
        .onAppear {
            guard let g = goal, title.isEmpty else { return }
            title = g.title; targetText = MoneyFormat.editString(g.target); savedText = MoneyFormat.editString(g.saved)
            hasDate = g.targetDate != nil; date = g.targetDate ?? date; accountID = g.accountID
        }
    }
}
