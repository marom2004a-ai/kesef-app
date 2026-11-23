import Foundation

public enum RecommendationSeverity: Int, Sendable, Comparable {
    case info = 0, suggestion = 1, warning = 2
    public static func < (l: RecommendationSeverity, r: RecommendationSeverity) -> Bool { l.rawValue < r.rawValue }
}

/// המלצה שכל מספר בה נגזר מהנתונים, עם הסבר על מה היא מבוססת.
public struct Recommendation: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// על אילו נתונים ההמלצה מבוססת
    public var basis: String
    public var monthlyPotential: Money?
    public var severity: RecommendationSeverity
}

public struct AdvisorInput: Sendable {
    public var now: Date
    public var entries: [EntrySnapshot]
    public var recurring: [RecurringSnapshot]
    public var categories: [CategorySnapshot]
    public var accounts: [AccountSnapshot]
    public init(now: Date, entries: [EntrySnapshot], recurring: [RecurringSnapshot], categories: [CategorySnapshot], accounts: [AccountSnapshot]) {
        self.now = now; self.entries = entries; self.recurring = recurring; self.categories = categories; self.accounts = accounts
    }
}

/// מנוע המלצות מבוסס כללים — בלי AI, בלי שירות חיצוני, בלי המצאת נתונים.
public enum SavingsAdvisor {

    public static func recommendations(_ input: AdvisorInput, calendar cal: FinanceCalendar = .israel) -> [Recommendation] {
        var recs: [Recommendation] = []
        let names = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0.name) })
        let analysis = IncomeAnalyzer.analyze(entries: input.entries, recurring: input.recurring, now: input.now, calendar: cal)
        let complete = analysis.months.filter(\.isComplete)
        let fmt = { (m: Money) in MoneyFormat.string(m) }

        // 1. קטגוריות שההוצאה בהן גדלה: חודש אחרון שלם מול ממוצע 3 החודשים שלפניו
        if complete.count >= 4 {
            let last = complete[complete.count - 1]
            let prev = complete[(complete.count - 4)..<(complete.count - 1)]
            let lastByCat = BalanceEngine.expensesByCategory(entries: input.entries, in: cal.monthRange(last.monthStart))
            var prevTotals: [UUID?: Money] = [:]
            for m in prev {
                for (k, v) in BalanceEngine.expensesByCategory(entries: input.entries, in: cal.monthRange(m.monthStart)) {
                    prevTotals[k, default: .zero] += v
                }
            }
            var growth: [(UUID, Money, Money)] = []
            for (key, lastValue) in lastByCat {
                guard let cat = key else { continue }
                let avg = Money(minorUnits: Money.roundedDivide((prevTotals[key] ?? .zero).minorUnits, by: 3))
                let diff = lastValue - avg
                // לפחות 20% וגם לפחות 200 ₪ עלייה
                if diff >= Money(shekels: 200), (Money.ratioBasisPoints(diff, of: avg) ?? 10_000) >= 2_000 {
                    growth.append((cat, avg, lastValue))
                }
            }
            for (cat, avg, lastValue) in growth.sorted(by: { ($0.2 - $0.1) > ($1.2 - $1.1) }).prefix(3) {
                let name = names[cat] ?? "קטגוריה"
                recs.append(Recommendation(
                    id: "growth-\(cat)", title: "ההוצאה על \(name) עלתה",
                    detail: "בחודש שעבר הוצאת \(fmt(lastValue)) על \(name), לעומת ממוצע של \(fmt(avg)) בשלושת החודשים שלפניו. חזרה לממוצע תחסוך כ-\(fmt(lastValue - avg)) בחודש.",
                    basis: "הוצאות מאושרות בקטגוריה \(name) ב-4 החודשים השלמים האחרונים.",
                    monthlyPotential: lastValue - avg, severity: .suggestion))
            }
        }

        // 2. חיובים קבועים לבדיקה — הגבוהים ביותר בעלות שנתית
        let activeFixed = input.recurring.filter { !$0.isPaused && $0.kind == .expense }
        if !activeFixed.isEmpty {
            let top = activeFixed.sorted { $0.monthlyEquivalent > $1.monthlyEquivalent }.prefix(3)
            let lines = top.map { "\($0.title): \(fmt($0.monthlyEquivalent)) בחודש (\(fmt($0.monthlyEquivalent * 12)) בשנה)" }
            recs.append(Recommendation(
                id: "review-fixed", title: "חיובים קבועים שכדאי לבדוק",
                detail: lines.joined(separator: "\n") + "\nכדאי לבדוק אם אפשר להוזיל, לאחד או לבטל.",
                basis: "\(activeFixed.count) חיובים קבועים פעילים, בסך \(fmt(analysis.fixedMonthly)) בחודש.",
                monthlyPotential: nil, severity: .info))
        }

        // 3. הוצאות לא חיוניות בחודש השלם האחרון
        if let last = complete.last {
            let nonEssential = Set(input.categories.filter { !$0.isEssential && !$0.isIncome }.map(\.id))
            let byCat = BalanceEngine.expensesByCategory(entries: input.entries, in: cal.monthRange(last.monthStart))
            var total = Money.zero
            for (k, v) in byCat { if let k, nonEssential.contains(k) { total += v } }
            if total >= Money(shekels: 100) {
                let potential = total.multiplied(byBasisPoints: 2_000)
                recs.append(Recommendation(
                    id: "non-essential", title: "הוצאות לא חיוניות",
                    detail: "בחודש שעבר הוצאת \(fmt(total)) בקטגוריות שסימנת כלא חיוניות. הפחתה של 20% שווה \(fmt(potential)) בחודש — \(fmt(potential * 12)) בשנה.",
                    basis: "קטגוריות המסומנות 'לא חיוני' בהגדרות, חודש שלם אחרון.",
                    monthlyPotential: potential, severity: .suggestion))
            }
        }

        // 4. יעד חיסכון חודשי ריאלי
        let window = Array(complete.suffix(6))
        if window.count >= 3 {
            let n = Int64(window.count)
            let avgIncome = Money(minorUnits: Money.roundedDivide(window.map(\.income).sum().minorUnits, by: n))
            let avgExp = Money(minorUnits: Money.roundedDivide(window.map(\.netExpenses).sum().minorUnits, by: n))
            let surplus = avgIncome - avgExp
            if surplus.isPositive {
                var goal = surplus.multiplied(byBasisPoints: 3_000)
                goal = Money(minorUnits: (goal.minorUnits / 5_000) * 5_000) // עיגול מטה ל-50 ₪
                recs.append(Recommendation(
                    id: "savings-goal", title: "יעד חיסכון חודשי ריאלי: \(fmt(goal))",
                    detail: "בממוצע נכנסו \(fmt(avgIncome)) ויצאו \(fmt(avgExp)) בחודש — עודף של \(fmt(surplus)). חיסכון של כ-30% מהעודף משאיר מרווח לחודשים חלשים.",
                    basis: "ממוצע \(window.count) החודשים השלמים האחרונים.",
                    monthlyPotential: goal, severity: .suggestion))
            } else {
                recs.append(Recommendation(
                    id: "deficit", title: "ההוצאות גבוהות מההכנסות",
                    detail: "בממוצע יצאו \(fmt(avgExp)) ונכנסו \(fmt(avgIncome)) בחודש — גירעון של \(fmt(surplus.absolute)). לפני יעד חיסכון כדאי לצמצם הוצאות.",
                    basis: "ממוצע \(window.count) החודשים השלמים האחרונים.",
                    monthlyPotential: nil, severity: .warning))
            }
        }

        // 5. כרית ביטחון לחודשים חלשים (עצמאי: 3 חודשי הוצאות בסיסיות)
        if window.count >= 3 {
            let n = Int64(window.count)
            let avgExp = Money(minorUnits: Money.roundedDivide(window.map(\.netExpenses).sum().minorUnits, by: n))
            let target = avgExp * 3
            let saved = BalanceEngine.savingsTotal(accounts: input.accounts, entries: input.entries)
            if saved < target {
                let gap = target - saved
                let monthly = Money(minorUnits: Money.roundedDivide(gap.minorUnits, by: 12))
                recs.append(Recommendation(
                    id: "reserve", title: "כרית ביטחון: חסרים \(fmt(gap))",
                    detail: "לעצמאי מומלץ להחזיק לפחות 3 חודשי הוצאות (\(fmt(target))). כרגע בחשבונות החיסכון \(fmt(saved)). כדי להגיע לשם בשנה צריך להפריש \(fmt(monthly)) בחודש.",
                    basis: "ממוצע ההוצאות ב-\(window.count) החודשים השלמים האחרונים ויתרות חשבונות מסוג חיסכון.",
                    monthlyPotential: nil, severity: .suggestion))
            }
            if let weakest = analysis.weakest, let ref = analysis.average6 ?? analysis.average3, weakest.income < ref {
                recs.append(Recommendation(
                    id: "weak-month", title: "פער בחודש חלש",
                    detail: "החודש החלש ביותר הכניס \(fmt(weakest.income)), \(fmt(ref - weakest.income)) פחות מהממוצע. כדאי שהכרית תכסה לפחות את הפער הזה.",
                    basis: "הכנסות מאושרות בחודשים השלמים האחרונים.",
                    monthlyPotential: nil, severity: .info))
            }
        }

        if complete.count < 3 {
            recs.append(Recommendation(
                id: "need-data", title: "צריך עוד נתונים",
                detail: "המלצות על ממוצעים, יעד חיסכון וכרית ביטחון מופיעות אחרי 3 חודשים שלמים של נתונים. כרגע יש \(complete.count).",
                basis: "מספר החודשים השלמים שנרשמו בהם תנועות.", monthlyPotential: nil, severity: .info))
        }
        return recs.sorted { $0.severity > $1.severity }
    }
}
