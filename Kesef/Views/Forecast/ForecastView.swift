import SwiftUI
import SwiftData
import Charts

struct ForecastView: View {
    @Query private var entries: [Entry]
    @Query private var accounts: [Account]
    @Query private var rules: [RecurringRule]
    @Query private var categories: [Category]
    @AppStorage(AppSettings.Key.vatRegistered) private var vatRegistered = true
    @AppStorage(AppSettings.Key.monthlySavingsMinor) private var savingsMinor = 0
    @AppStorage(AppSettings.Key.partnerShareBP) private var partnerBP = 0
    @State private var days = 30
    @State private var scenario: Scenario = .base
    @State private var includeVariable = true

    private let cal = FinanceCalendar.israel

    private func results() -> [Scenario: ForecastResult] {
        let input = ForecastInput(now: .now, horizonEnd: cal.addDays(days, to: cal.startOfDay(.now)),
                                  accounts: accounts.map(\.snapshot), entries: entries.map(\.snapshot),
                                  recurring: rules.map(\.snapshot), partner: partnerBP > 0 ? AppSettings.partner : nil,
                                  monthlySavingsTarget: Money(minorUnits: Int64(savingsMinor)), includeVariableSpending: includeVariable,
                                  vat: vatRegistered ? AppSettings.vat : nil,
                                  vatDeductibleBP: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.vatDeductibleBP) }))
        var r: [Scenario: ForecastResult] = [:]
        for s in Scenario.allCases { r[s] = ForecastEngine.run(input, scenario: s, calendar: cal) }
        return r
    }

    var body: some View {
        let all = results()
        let selected = all[scenario]!
        List {
            Section {
                Picker("טווח", selection: $days) {
                    Text("7 ימים").tag(7); Text("14 ימים").tag(14); Text("30 ימים").tag(30)
                }.pickerStyle(.segmented)
                if let last = BalanceEngine.lastBalanceUpdate(accounts: accounts.map(\.snapshot)) {
                    Label("יתרות עודכנו לאחרונה: \(Fmt.dateTime(last))", systemImage: "building.columns")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("זו תחזית לפי הנתונים שהוזנו — לא יתרת בנק חיה.").font(.caption).foregroundStyle(Theme.forecast)
            }

            Section {
                Chart {
                    ForEach(Scenario.allCases) { s in
                        ForEach(all[s]!.points) { p in
                            // המרה ל-Double לציור הגרף בלבד — כל החישובים נעשים באגורות
                            LineMark(x: .value("תאריך", p.date), y: .value("יתרה", NSDecimalNumber(decimal: p.balance.decimalValue).doubleValue))
                                .foregroundStyle(by: .value("תרחיש", s.label))
                                .interpolationMethod(.stepEnd)
                        }
                    }
                    RuleMark(y: .value("אפס", 0.0)).foregroundStyle(Theme.expense.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartForegroundStyleScale([Scenario.conservative.label: Theme.warning,
                                            Scenario.base.label: Theme.accent,
                                            Scenario.optimistic.label: Theme.income])
                .frame(height: 220)
                .environment(\.layoutDirection, .leftToRight)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("תרחיש").font(.caption).foregroundStyle(.secondary)
                        Text("בסוף הטווח").font(.caption).foregroundStyle(.secondary)
                        Text("נמוך ביותר").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Scenario.allCases) { s in
                        GridRow {
                            Text(s.label)
                            MoneyText(money: all[s]!.endBalance, font: .subheadline.weight(.semibold), colored: true)
                            MoneyText(money: all[s]!.minBalance, font: .subheadline, colored: true)
                        }
                    }
                }
            }

            if let neg = all[.conservative]!.firstNegativeDate {
                Section {
                    Label("סיכון ליתרה שלילית: בתרחיש השמרני היתרה יורדת מתחת לאפס ב-\(Fmt.dayMonth(neg)).", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.expense).font(.subheadline.weight(.semibold))
                }
            }

            Section {
                Picker("תרחיש", selection: $scenario) { ForEach(Scenario.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("לכלול הוצאות שוטפות משוערות", isOn: $includeVariable)
            }

            Section("לוח חיובים והכנסות — \(scenario.label)") {
                let events = selected.events.filter { $0.kind != .variableSpending }
                if events.isEmpty { Text("אין אירועים מתוכננים בטווח.").foregroundStyle(.secondary) }
                ForEach(events) { e in
                    HStack {
                        Text(Fmt.dayMonth(e.date)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(e.title.isEmpty ? e.kind.label : e.title).lineLimit(1)
                            Text(e.kind.label).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoneyText(money: e.amount, font: .subheadline.weight(.semibold), colored: true, showPlus: true)
                    }
                }
            }

            Section("הנחות התחזית") {
                ForEach(selected.assumptions, id: \.self) { Text($0).font(.footnote) }
            }
        }
        .navigationTitle("תזרים עתידי")
    }
}
