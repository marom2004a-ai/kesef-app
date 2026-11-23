import Foundation

/// הגדרות מע״מ לעוסק מורשה. הסכומים באפליקציה נרשמים ברוטו (כולל מע״מ), והמע״מ מחולץ מתוכם.
public struct VatSettings: Hashable, Sendable {
    public var isRegistered: Bool
    /// שיעור המע״מ בנקודות בסיס: 1800 = 18%
    public var rateBasisPoints: Int
    /// תקופת דיווח: 1 = חודשי, 2 = דו-חודשי
    public var periodMonths: Int
    /// יום התשלום בחודש שאחרי סוף התקופה
    public var dueDay: Int

    public init(isRegistered: Bool, rateBasisPoints: Int = 1800, periodMonths: Int = 2, dueDay: Int = 15) {
        self.isRegistered = isRegistered; self.rateBasisPoints = rateBasisPoints
        self.periodMonths = periodMonths == 1 ? 1 : 2; self.dueDay = dueDay
    }
}

public struct VatStatement: Hashable, Sendable {
    public var period: Range<Date>
    public var dueDate: Date
    /// הכנסות עסקיות כולל מע״מ
    public var incomeGross: Money = .zero
    /// מע״מ עסקאות (על ההכנסות)
    public var outputVAT: Money = .zero
    /// הוצאות עסקיות נטו מזיכויים, כולל מע״מ
    public var expensesGross: Money = .zero
    /// מע״מ תשומות מוכר (על ההוצאות)
    public var inputVAT: Money = .zero
    /// מע״מ ששולם לרשויות בתקופה שאחרי סוף התקופה (תנועות taxPayment שסומנו לתקופה)
    public var vatPaid: Money = .zero

    /// מע״מ לתשלום (שלילי = החזר)
    public var vatPayable: Money { outputVAT - inputVAT }
    public var incomeNet: Money { incomeGross - outputVAT }
    /// הוצאה בפועל לעסק: ברוטו פחות המע״מ שמקוזז
    public var expensesNet: Money { expensesGross - inputVAT }
    /// רווח לפני מס הכנסה וביטוח לאומי
    public var profitBeforeTax: Money { incomeNet - expensesNet }
}

public enum VatEngine {

    /// המע״מ הכלול בסכום ברוטו: ברוטו × שיעור ÷ (1 + שיעור). 118 ₪ ב-18% → 18 ₪
    public static func vatIncluded(in gross: Money, rateBasisPoints: Int) -> Money {
        guard rateBasisPoints > 0 else { return .zero }
        return Money(minorUnits: Money.roundedDivide(gross.minorUnits * Int64(rateBasisPoints), by: Int64(10_000 + rateBasisPoints)))
    }

    /// תקופת הדיווח שמכילה את התאריך. דו-חודשי: ינואר–פברואר, מרץ–אפריל, …
    public static func period(containing d: Date, settings: VatSettings, calendar cal: FinanceCalendar = .israel) -> Range<Date> {
        let month = cal.calendar.component(.month, from: d)
        let offset = (month - 1) % settings.periodMonths
        let start = cal.addMonths(-offset, to: cal.startOfMonth(d))
        return start..<cal.addMonths(settings.periodMonths, to: start)
    }

    public static func previousPeriod(before p: Range<Date>, settings: VatSettings, calendar cal: FinanceCalendar = .israel) -> Range<Date> {
        period(containing: cal.addDays(-1, to: p.lowerBound), settings: settings, calendar: cal)
    }

    /// מועד התשלום: יום dueDay בחודש שאחרי סוף התקופה
    public static func dueDate(for p: Range<Date>, settings: VatSettings, calendar cal: FinanceCalendar = .israel) -> Date {
        cal.date(inMonthOf: p.upperBound, day: settings.dueDay)
    }

    /// דוח מע״מ לתקופה. deductibleBP: אחוז המע״מ המוכר לפי קטגוריה (ברירת מחדל 100%).
    public static func statement(entries: [EntrySnapshot], period p: Range<Date>, settings: VatSettings,
                                 deductibleBP: [UUID: Int] = [:], calendar cal: FinanceCalendar = .israel) -> VatStatement {
        var s = VatStatement(period: p, dueDate: dueDate(for: p, settings: settings, calendar: cal))
        let rate = settings.isRegistered ? settings.rateBasisPoints : 0
        for e in entries where e.status == .confirmed && e.scope == .business && p.contains(e.date) {
            switch e.kind {
            case .income:
                s.incomeGross += e.amount
                s.outputVAT += e.vatOverride ?? vatIncluded(in: e.amount, rateBasisPoints: rate)
            case .expense, .refund:
                let sign: Int64 = e.kind == .expense ? 1 : -1
                let bp = e.categoryID.flatMap { deductibleBP[$0] } ?? 10_000
                let fullVAT = e.vatOverride ?? vatIncluded(in: e.amount, rateBasisPoints: rate)
                s.expensesGross += Money(minorUnits: sign * e.amount.minorUnits)
                s.inputVAT += Money(minorUnits: sign * fullVAT.multiplied(byBasisPoints: bp).minorUnits)
            default:
                break
            }
        }
        if !settings.isRegistered { s.outputVAT = .zero; s.inputVAT = .zero }
        // תשלומי מע״מ: תנועות taxPayment מהיום שאחרי סוף התקופה ועד מועד התשלום + 10 ימים
        let payWindow = p.upperBound..<cal.addDays(11, to: s.dueDate)
        s.vatPaid = entries.filter { $0.status == .confirmed && $0.kind == .taxPayment && payWindow.contains($0.date) }
            .map(\.amount).sum()
        return s
    }
}

// MARK: - חלוקה עם שותף אחרי מע״מ

public struct PartnerSplit: Hashable, Sendable {
    /// בסיס החלוקה (רווח אחרי מע״מ או הכנסות נטו)
    public var base: Money
    public var partnerShare: Money
    public var myShare: Money
    public var paidToPartner: Money
    public var stillOwedToPartner: Money { partnerShare - paidToPartner }
}

public extension PartnerEngine {
    /// חלוקה לשותף כשהעסק עוסק מורשה: הבסיס הוא הרווח אחרי שמנכים את המע״מ (שאינו שייך לעסק).
    static func split(entries: [EntrySnapshot], period: Range<Date>, partner: PartnerSettings, vat: VatSettings,
                      deductibleBP: [UUID: Int] = [:], calendar cal: FinanceCalendar = .israel) -> PartnerSplit {
        let st = VatEngine.statement(entries: entries, period: period, settings: vat, deductibleBP: deductibleBP, calendar: cal)
        let base = partner.basis == .profit ? st.profitBeforeTax : st.incomeNet
        let partnerShare = base.isPositive ? base.multiplied(byBasisPoints: partner.shareBasisPoints) : .zero
        let paid = entries.filter { $0.status == .confirmed && $0.kind == .partnerPayout && period.contains($0.date) }
            .map(\.amount).sum()
        return PartnerSplit(base: base, partnerShare: partnerShare, myShare: base - partnerShare, paidToPartner: paid)
    }
}
