import SwiftUI
import SwiftData

/// כותרת לתקופת דיווח: "נוב׳–דצמ׳ 2026" או "נובמבר 2026"
func reportPeriodTitle(_ p: Range<Date>, months: Int, calendar cal: FinanceCalendar = .israel) -> String {
    let last = cal.addDays(-1, to: p.upperBound)
    if months == 1 { return Fmt.monthYear(p.lowerBound) }
    return "\(Fmt.shortMonth(p.lowerBound))–\(Fmt.shortMonth(last)) \(cal.calendar.component(.year, from: last))"
}

/// דוח הכנסות (והוצאות) דו-חודשי של העסק — מסודר לתקופות המע״מ, עם ייצוא לרואה החשבון.
struct BusinessPeriodReportView: View {
    @Query(filter: #Predicate<Entry> { $0.scopeRaw == "business" }) private var entries: [Entry]
    @Query private var categories: [Category]
    @AppStorage(AppSettings.Key.vatRegistered) private var registered = true
    @AppStorage(AppSettings.Key.vatRateBP) private var rateBP = 1800
    @AppStorage(AppSettings.Key.vatPeriodMonths) private var periodMonths = 2

    enum Tab: String, CaseIterable, Identifiable { case income = "הכנסות", expenses = "הוצאות"; var id: String { rawValue } }

    @State private var anchor = Date.now
    @State private var tab: Tab = .income
    @State private var editing: Entry?
    @State private var attachTo: Entry?
    @State private var deleting: Entry?
    @Environment(\.modelContext) private var context
    @State private var exportItems: [URL] = []
    @State private var error: String?

    private let cal = FinanceCalendar.israel
    private var settings: VatSettings { VatSettings(isRegistered: registered, rateBasisPoints: rateBP, periodMonths: periodMonths) }

    var body: some View {
        let period = VatEngine.period(containing: anchor, settings: settings, calendar: cal)
        let inPeriod = entries.filter { period.contains($0.date) }
        let withPhoto = Set(inPeriod.filter { $0.receiptImage != nil }.map(\.id))
        let deductible = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.vatDeductibleBP) })
        let report = PeriodReportEngine.build(entries: inPeriod.map(\.snapshot), withReceipt: withPhoto, period: period,
                                              settings: settings, deductibleBP: deductible)
        let byID = Dictionary(uniqueKeysWithValues: inPeriod.map { ($0.id, $0) })
        let catNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })

        List {
            Section {
                HStack {
                    Button { anchor = cal.addMonths(-periodMonths, to: period.lowerBound); exportItems = [] } label: { Image(systemName: "chevron.right") }
                    Spacer()
                    VStack {
                        Text(reportPeriodTitle(period, months: periodMonths)).font(.headline)
                        Text(periodMonths == 2 ? "תקופת דיווח דו-חודשית" : "תקופת דיווח חודשית").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { anchor = period.upperBound; exportItems = [] } label: { Image(systemName: "chevron.left") }
                }
                .buttonStyle(.borderless)
            }
            if let error { Section { ErrorBanner(message: error) } }

            Section("סיכום התקופה") {
                LabeledContent("הכנסות כולל מע״מ") { MoneyText(money: report.incomeGross, font: .title3.weight(.bold)) }
                if registered {
                    LabeledContent("מתוכן מע״מ") { MoneyText(money: report.incomeVAT) }
                    LabeledContent("הכנסות לפני מע״מ") { MoneyText(money: report.incomeNet, font: .headline) }
                }
                LabeledContent("הוצאות כולל מע״מ") { MoneyText(money: report.expensesGross) }
                if registered { LabeledContent("מע״מ תשומות מוכר") { MoneyText(money: report.expensesVAT) } }
                LabeledContent("רווח לפני מס") { MoneyText(money: report.incomeNet - report.expensesNet, font: .headline, colored: true) }
                if report.expensesMissingReceipt > 0 {
                    Label(report.expensesMissingReceipt == 1 ? "הוצאה אחת בלי צילום קבלה" : "\(report.expensesMissingReceipt) הוצאות בלי צילום קבלה",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(Theme.warning)
                }
            }

            Section {
                Picker("תצוגה", selection: $tab) {
                    ForEach(Tab.allCases) { Text("\($0.rawValue) (\($0 == .income ? report.income.count : report.expenses.count))").tag($0) }
                }
                .pickerStyle(.segmented)
                let lines = tab == .income ? report.income : report.expenses
                if lines.isEmpty {
                    Text(tab == .income ? "אין הכנסות עסקיות מאושרות בתקופה הזו." : "אין הוצאות עסקיות מאושרות בתקופה הזו.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(lines) { l in
                    Button { editing = byID[l.id] } label: { row(l, category: l.categoryID.flatMap { catNames[$0] }) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            if tab == .expenses && !l.hasReceipt && l.kind == .expense {
                                Button { attachTo = byID[l.id] } label: { Label("צילום קבלה", systemImage: "camera") }.tint(Theme.accent)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = byID[l.id] } label: { Label("מחיקה", systemImage: "trash") }
                        }
                }
            } footer: {
                Text(tab == .expenses ? "החלקה ימינה על הוצאה בלי קבלה מאפשרת לצלם לה קבלה. לחיצה פותחת לעריכה, החלקה שמאלה מוחקת." : "רק הכנסות עסקיות שסומנו כ״התקבלה בפועל״. לחיצה פותחת לעריכה, החלקה שמאלה מוחקת.")
            }

            Section {
                Button { export(report, catNames: catNames, byID: byID) } label: {
                    Label("הכנת דוח לרואה החשבון", systemImage: "doc.badge.arrow.up")
                }
                if !exportItems.isEmpty {
                    ShareLink(items: exportItems) {
                        Label(exportItems.count > 1 ? "שיתוף הדוח + \(exportItems.count - 1) צילומי קבלות" : "שיתוף הדוח (CSV)",
                              systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("קובץ CSV שנפתח באקסל: כל ההכנסות וההוצאות של התקופה עם מע״מ ולפני מע״מ, וצילומי הקבלות כקבצים נפרדים. אפשר לשלוח בוואטסאפ, במייל או לשמור ב-Files. החישוב מבוסס על מה שהוזן — לא תחליף לדיווח הרשמי.")
            }
        }
        .navigationTitle("דוח הכנסות")
        .kesefScreen()
        .sheet(item: $editing) { e in NavigationStack { EntryEditorView(existing: e) } }
        .sheet(item: $attachTo) { e in NavigationStack { ExpenseReceiptCaptureView(attachTo: e) } }
        .confirmationDialog("למחוק את התנועה?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {
                if let e = deleting { try? LedgerService(context: context).delete(e); exportItems = [] }
                deleting = nil
            }
        } message: { Text("למשהו שנרשם בטעות. התנועה תימחק מהדוח ומהמע״מ — אי אפשר לבטל.") }
    }

    private func row(_ l: PeriodReportLine, category: String?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.title.isEmpty ? (l.kind == .income ? "הכנסה" : "הוצאה") : l.title).lineLimit(1)
                Text([Fmt.date(l.date), category, l.kind == .refund ? "זיכוי" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if tab == .expenses && l.kind == .expense {
                Image(systemName: l.hasReceipt ? "doc.text.image.fill" : "camera.badge.ellipsis")
                    .foregroundStyle(l.hasReceipt ? Theme.income : Theme.warning)
                    .accessibilityLabel(l.hasReceipt ? "יש צילום קבלה" : "אין צילום קבלה")
            }
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(money: l.gross, font: .body.weight(.semibold))
                if registered && !l.vat.isZero {
                    Text("מע״מ \(MoneyFormat.string(l.vat))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func export(_ r: PeriodReport, catNames: [UUID: String], byID: [UUID: Entry]) {
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("doch-\(cal.monthKey(r.period.lowerBound))", isDirectory: true)
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let csvURL = dir.appendingPathComponent("doch-hachnasot-\(cal.monthKey(r.period.lowerBound)).csv")
            try PeriodReportEngine.csv(r, categoryNames: catNames, calendar: cal).data(using: .utf8)!
                .write(to: csvURL, options: [.atomic, .completeFileProtection])
            var items = [csvURL]
            let f = DateFormatter(); f.calendar = cal.calendar; f.timeZone = cal.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
            for (i, l) in r.expenses.enumerated() where l.hasReceipt {
                guard let data = byID[l.id]?.receiptImage else { continue }
                let safe = l.title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined().prefix(30)
                let url = dir.appendingPathComponent("kabala-\(f.string(from: l.date))-\(i + 1)-\(safe).jpg")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                items.append(url)
            }
            exportItems = items
            error = nil
        } catch {
            self.error = "יצירת הדוח נכשלה: \(error.localizedDescription)"
        }
    }
}
