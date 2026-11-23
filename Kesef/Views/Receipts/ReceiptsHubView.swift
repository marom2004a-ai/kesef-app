import SwiftUI
import SwiftData

/// לשונית "קבלות ודוחות": כל מה שקשור לניירת של העסק במקום אחד
struct ReceiptsHubView: View {
    @Query(filter: #Predicate<Entry> { $0.scopeRaw == "business" }) private var business: [Entry]
    @Query(sort: \IssuedDocument.createdAt, order: .reverse) private var docs: [IssuedDocument]
    @Query private var categories: [Category]
    @AppStorage(AppSettings.Key.vatRegistered) private var registered = true
    @AppStorage(AppSettings.Key.vatRateBP) private var rateBP = 1800
    @AppStorage(AppSettings.Key.vatPeriodMonths) private var periodMonths = 2
    @State private var showCapture = false

    private let cal = FinanceCalendar.israel

    var body: some View {
        let settings = VatSettings(isRegistered: registered, rateBasisPoints: rateBP, periodMonths: periodMonths)
        let period = VatEngine.period(containing: .now, settings: settings, calendar: cal)
        let inPeriod = business.filter { period.contains($0.date) }
        let withPhoto = Set(inPeriod.filter { $0.receiptImage != nil }.map(\.id))
        let report = PeriodReportEngine.build(entries: inPeriod.map(\.snapshot), withReceipt: withPhoto, period: period, settings: settings,
                                              deductibleBP: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.vatDeductibleBP) }))
        let st = VatEngine.statement(entries: inPeriod.map(\.snapshot), period: period, settings: settings, calendar: cal)
        let expenseCount = report.expenses.filter { $0.kind == .expense }.count

        ScrollView {
            VStack(spacing: 14) {
                periodCard(period: period, report: report, vatPayable: st.vatPayable, due: st.dueDate, expenseCount: expenseCount)

                HStack(spacing: 10) {
                    Button { showCapture = true } label: {
                        HubTileLabel(title: "צילום קבלת הוצאה", symbol: "camera.fill", subtitle: "סריקה וחיתוך אוטומטי", highlighted: true)
                    }
                    .buttonStyle(.plain)
                    HubTile(title: "הפקת קבלה ללקוח", symbol: "doc.badge.plus", subtitle: "דרך morning") { IssueReceiptView() }
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    HubTile(title: "דוח הכנסות דו-חודשי", symbol: "doc.text.magnifyingglass", subtitle: "ייצוא לרואה החשבון") { BusinessPeriodReportView() }
                    HubTile(title: "מע״מ ומרום", symbol: "percent", subtitle: "מה לשלם ומה לחלק") { VatReportView() }
                    HubTile(title: "קבלות ההוצאות", symbol: "tray.full.fill", subtitle: "\(business.filter { $0.receiptImage != nil }.count) צילומים") { ExpenseReceiptsListView() }
                    HubTile(title: "קבלות שהפקתי", symbol: "doc.text.fill", subtitle: "\(docs.filter(\.isReal).count) מסמכים") { ReceiptsListView() }
                    HubTile(title: "דוחות וניתוח", symbol: "chart.bar.xaxis") { ReportsView() }
                    HubTile(title: "ייבוא דוח (אקסל)", symbol: "square.and.arrow.down") { CSVImportView() }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .kesefScreen()
        .navigationTitle("קבלות ודוחות")
        .sheet(isPresented: $showCapture) { NavigationStack { ExpenseReceiptCaptureView() } }
        .onAppear { celebrateIfComplete(report: report, period: period, expenseCount: expenseCount) }
    }

    private func periodCard(period: Range<Date>, report: PeriodReport, vatPayable: Money, due: Date, expenseCount: Int) -> some View {
        let done = expenseCount - report.expensesMissingReceipt
        let progress = expenseCount == 0 ? 1.0 : Double(done) / Double(expenseCount)
        return NavigationLink { BusinessPeriodReportView() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("התקופה הנוכחית · \(reportPeriodTitle(period, months: periodMonths))").font(.subheadline).foregroundStyle(Theme.mutedText)
                    Spacer()
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedText)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("הכנסות").font(.caption).foregroundStyle(Theme.mutedText)
                        MoneyText(money: report.incomeGross, font: .system(size: 30, weight: .bold, design: .rounded), color: Theme.goldBright)
                    }
                    Spacer()
                    if registered {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(vatPayable.isNegative ? "החזר מע״מ" : "מע״מ ל-\(Fmt.dayMonth(due))").font(.caption).foregroundStyle(Theme.mutedText)
                            MoneyText(money: vatPayable.absolute, font: .headline)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(report.expensesMissingReceipt == 0 ? "כל הקבלות צולמו ✓" : "חסרות \(report.expensesMissingReceipt) קבלות")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(report.expensesMissingReceipt == 0 ? Theme.income : Theme.warning)
                        Spacer()
                        Text("\(done)/\(expenseCount)").font(.caption).monospacedDigit().foregroundStyle(Theme.mutedText)
                    }
                    ProgressView(value: progress).tint(report.expensesMissingReceipt == 0 ? Theme.income : Theme.gold)
                }
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    /// חגיגה כשכל קבלות התקופה צולמו (פעם אחת לתקופה)
    private func celebrateIfComplete(report: PeriodReport, period: Range<Date>, expenseCount: Int) {
        guard expenseCount >= 3, report.expensesMissingReceipt == 0 else { return }
        Celebrations.shared.celebrate("receipts-\(cal.monthKey(period.lowerBound))", message: "כל הקבלות של התקופה מסודרות! 🐾")
    }
}
