import SwiftUI
import SwiftData

/// דוח מע״מ לתקופה + רווח העסק אחרי מע״מ + חלוקה בין השותפים.
struct VatReportView: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @Query private var categories: [Category]
    @AppStorage(AppSettings.Key.vatRegistered) private var registered = true
    @AppStorage(AppSettings.Key.vatRateBP) private var rateBP = 1800
    @AppStorage(AppSettings.Key.vatPeriodMonths) private var periodMonths = 2
    @AppStorage(AppSettings.Key.partnerName) private var partnerName = "מרום"
    @AppStorage(AppSettings.Key.partnerShareBP) private var partnerBP = 5000
    @AppStorage(AppSettings.Key.partnerBasis) private var basisRaw = PartnerBasis.profit.rawValue

    @State private var anchor = Date.now
    @State private var showPayVAT = false
    @State private var showPayPartner = false
    @State private var error: String?

    private let cal = FinanceCalendar.israel
    private var settings: VatSettings { VatSettings(isRegistered: registered, rateBasisPoints: rateBP, periodMonths: periodMonths) }

    var body: some View {
        let snaps = entries.map(\.snapshot)
        let deductible = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.vatDeductibleBP) })
        let period = VatEngine.period(containing: anchor, settings: settings, calendar: cal)
        let st = VatEngine.statement(entries: snaps, period: period, settings: settings, deductibleBP: deductible, calendar: cal)
        let partner = PartnerSettings(name: partnerName, shareBasisPoints: partnerBP, basis: PartnerBasis(rawValue: basisRaw) ?? .profit)
        let split = PartnerEngine.split(entries: snaps, period: period, partner: partner, vat: settings, deductibleBP: deductible, calendar: cal)

        List {
            Section {
                HStack {
                    Button { anchor = cal.addMonths(-periodMonths, to: period.lowerBound) } label: { Image(systemName: "chevron.right") }
                    Spacer()
                    VStack {
                        Text(periodTitle(period)).font(.headline)
                        Text(periodMonths == 2 ? "תקופה דו-חודשית" : "תקופה חודשית").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { anchor = period.upperBound } label: { Image(systemName: "chevron.left") }
                }
                .buttonStyle(.borderless)
                if !registered {
                    Label("מוגדר כעוסק פטור — אין חישוב מע״מ. אפשר לשנות בהגדרות.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { ErrorBanner(message: error) } }

            if registered {
                Section {
                    row("הכנסות העסק (כולל מע״מ)", st.incomeGross)
                    row("מע״מ עסקאות", st.outputVAT)
                    row("הוצאות העסק (כולל מע״מ)", st.expensesGross)
                    row("מע״מ תשומות מוכר", st.inputVAT)
                    LabeledContent(st.vatPayable.isNegative ? "החזר מע״מ צפוי" : "מע״מ לתשלום") {
                        MoneyText(money: st.vatPayable.absolute, font: .title3.weight(.bold))
                    }
                    LabeledContent("מועד תשלום") { Text(Fmt.date(st.dueDate)) }
                    if st.vatPaid.isPositive {
                        LabeledContent("שולם") { MoneyText(money: st.vatPaid) }
                        LabeledContent("נותר לשלם") { MoneyText(money: st.vatPayable - st.vatPaid, colored: true) }
                    }
                    Button { showPayVAT = true } label: { Label("רישום תשלום מע״מ", systemImage: "checkmark.circle") }
                        .disabled(!st.vatPayable.isPositive)
                } header: { Text("מע״מ \(rateBP / 100)%") }
                  footer: { Text("המע״מ מחושב מתוך הסכומים שנרשמו (כוללי מע״מ) בהכנסות והוצאות עסקיות מאושרות. בקטגוריות כמו רכב מוכר רק חלק מהמע״מ — ניתן לשנות בקטגוריות. אם בדוח שיובא הייתה עמודת מע״מ — נלקח הסכום המדויק ממנה.") }
            }

            Section {
                row("הכנסות נטו (בלי מע״מ)", st.incomeNet)
                row("הוצאות נטו", st.expensesNet)
                LabeledContent("רווח העסק לפני מס הכנסה") { MoneyText(money: st.profitBeforeTax, font: .title3.weight(.bold), colored: true) }
            } header: { Text("רווח העסק") }

            if partnerBP > 0 {
                Section {
                    LabeledContent("החלק שלי (\((10_000 - partnerBP) / 100)%)") { MoneyText(money: split.myShare, font: .headline) }
                    LabeledContent("החלק של \(partnerName) (\(partnerBP / 100)%)") { MoneyText(money: split.partnerShare, font: .headline) }
                    LabeledContent("שולם ל\(partnerName) בתקופה") { MoneyText(money: split.paidToPartner) }
                    LabeledContent(split.stillOwedToPartner.isNegative ? "שולם ל\(partnerName) יותר מחלקו" : "נותר להעביר ל\(partnerName)") {
                        MoneyText(money: split.stillOwedToPartner.absolute, font: .headline, colored: false)
                    }
                    Button { showPayPartner = true } label: { Label("רישום העברה ל\(partnerName)", systemImage: "arrow.left.arrow.right") }
                        .disabled(!split.stillOwedToPartner.isPositive)
                } header: { Text("חלוקה בין השותפים") }
                  footer: { Text(PartnerBasis(rawValue: basisRaw) == .revenue ? "החלוקה מההכנסות נטו (בלי מע״מ)." : "החלוקה מהרווח אחרי מע״מ והוצאות. מס הכנסה וביטוח לאומי אישיים לכל שותף ואינם מחושבים כאן.") }
            }

            Section {
                Text("החישוב מבוסס רק על הנתונים שהוזנו או יובאו, ואינו תחליף לרואה חשבון או לדיווח הרשמי לרשות המסים.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("מע״מ וחלוקת רווח")
        .sheet(isPresented: $showPayVAT) {
            AmountPromptView(title: "תשלום מע״מ", confirmTitle: "רישום") { m, d in
                let e = Entry(kind: .taxPayment, status: .confirmed, amount: m, date: d, title: "תשלום מע״מ \(periodTitle(period))", scope: .business)
                e.accountID = Ledger(context: context).accounts().first { $0.kind == .businessBank }?.id
                context.insert(e)
                try context.save()
            }
        }
        .sheet(isPresented: $showPayPartner) {
            AmountPromptView(title: "העברה ל\(partnerName)", confirmTitle: "רישום") { m, d in
                // העברה שנעשית אחרי סוף התקופה עבור התקופה הזו — נרשמת ביום האחרון של התקופה כדי להיספר בחלוקה שלה
                let lastDay = cal.calendar.date(byAdding: .hour, value: 12, to: cal.addDays(-1, to: period.upperBound)) ?? d
                let e = Entry(kind: .partnerPayout, status: .confirmed, amount: m, date: min(d, lastDay),
                              title: "חלוקת רווח ל\(partnerName) — \(periodTitle(period))", scope: .business)
                if d > lastDay { e.note = "שולם בפועל ב-\(Fmt.date(d))" }
                e.accountID = Ledger(context: context).accounts().first { $0.kind == .businessBank }?.id
                context.insert(e)
                try context.save()
            }
        }
    }

    private func row(_ title: String, _ m: Money) -> some View {
        LabeledContent(title) { MoneyText(money: m) }
    }

    private func periodTitle(_ p: Range<Date>) -> String {
        let last = cal.addDays(-1, to: p.upperBound)
        if periodMonths == 1 { return Fmt.monthYear(p.lowerBound) }
        return "\(Fmt.shortMonth(p.lowerBound))–\(Fmt.shortMonth(last)) \(cal.calendar.component(.year, from: last))"
    }
}
