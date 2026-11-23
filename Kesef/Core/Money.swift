import Foundation

/// סכום כסף מדויק בשקלים, נשמר כמספר שלם של אגורות.
/// אין שימוש ב-Double בשום חישוב כספי.
public struct Money: Hashable, Codable, Comparable, Sendable {
    /// אגורות (1 ₪ = 100)
    public var minorUnits: Int64

    public init(minorUnits: Int64) { self.minorUnits = minorUnits }

    public init(shekels: Int64, agorot: Int64 = 0) {
        self.minorUnits = shekels * 100 + (shekels < 0 ? -agorot : agorot)
    }

    /// המרה מ-Decimal עם עיגול חצי-למעלה (מהאפס והלאה) לאגורה הקרובה.
    public init(decimal: Decimal) {
        var value = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        self.minorUnits = NSDecimalNumber(decimal: rounded).int64Value
    }

    public static let zero = Money(minorUnits: 0)

    public var decimalValue: Decimal { Decimal(minorUnits) / 100 }
    public var isZero: Bool { minorUnits == 0 }
    public var isNegative: Bool { minorUnits < 0 }
    public var isPositive: Bool { minorUnits > 0 }
    public var absolute: Money { Money(minorUnits: Swift.abs(minorUnits)) }

    public static func + (l: Money, r: Money) -> Money { Money(minorUnits: l.minorUnits + r.minorUnits) }
    public static func - (l: Money, r: Money) -> Money { Money(minorUnits: l.minorUnits - r.minorUnits) }
    public static prefix func - (m: Money) -> Money { Money(minorUnits: -m.minorUnits) }
    public static func += (l: inout Money, r: Money) { l.minorUnits += r.minorUnits }
    public static func -= (l: inout Money, r: Money) { l.minorUnits -= r.minorUnits }
    public static func < (l: Money, r: Money) -> Bool { l.minorUnits < r.minorUnits }

    public static func * (l: Money, r: Int) -> Money { Money(minorUnits: l.minorUnits * Int64(r)) }

    /// הכפלה באחוז הנתון בנקודות בסיס (100% = 10000), עיגול חצי-מהאפס.
    public func multiplied(byBasisPoints bp: Int) -> Money {
        Money(minorUnits: Money.roundedDivide(minorUnits * Int64(bp), by: 10_000))
    }

    /// הכפלה ביחס עשרוני מדויק.
    public func multiplied(by ratio: Decimal) -> Money {
        Money(decimal: decimalValue * ratio)
    }

    /// חלוקה ל-n חלקים שסכומם שווה בדיוק לסכום המקורי (השארית מתחלקת באגורות לחלקים הראשונים).
    public func split(into parts: Int) -> [Money] {
        guard parts > 0 else { return [] }
        let base = minorUnits / Int64(parts)
        var remainder = minorUnits - base * Int64(parts)
        var result: [Money] = []
        for _ in 0..<parts {
            var v = base
            if remainder > 0 { v += 1; remainder -= 1 } else if remainder < 0 { v -= 1; remainder += 1 }
            result.append(Money(minorUnits: v))
        }
        return result
    }

    /// יחס בנקודות בסיס (value / total * 10000) — לאחוזי ניצול.
    public static func ratioBasisPoints(_ value: Money, of total: Money) -> Int? {
        guard total.minorUnits != 0 else { return nil }
        return Int(roundedDivide(value.minorUnits * 10_000, by: total.minorUnits))
    }

    static func roundedDivide(_ a: Int64, by b: Int64) -> Int64 {
        precondition(b != 0)
        let q = a / b
        let r = a % b
        if r == 0 { return q }
        let negative = (a < 0) != (b < 0)
        if Swift.abs(r) * 2 >= Swift.abs(b) { return negative ? q - 1 : q + 1 }
        return q
    }
}

public extension Sequence where Element == Money {
    func sum() -> Money { reduce(.zero, +) }
}

// MARK: - תצוגה

public enum MoneyFormat {
    /// "1,234.50 ₪" / "‎-1,234 ₪". אגורות מוצגות רק כשיש.
    public static func string(_ m: Money, alwaysShowAgorot: Bool = false, showPlus: Bool = false) -> String {
        let negative = m.minorUnits < 0
        let absValue = m.minorUnits.magnitude
        let shekels = absValue / 100
        let agorot = absValue % 100
        var digits = String(shekels)
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + String(digits.suffix(3)) + grouped
            digits = String(digits.dropLast(3))
        }
        grouped = digits + grouped
        if agorot != 0 || alwaysShowAgorot {
            grouped += "." + (agorot < 10 ? "0" : "") + String(agorot)
        }
        let sign = negative ? "-" : (showPlus && m.minorUnits > 0 ? "+" : "")
        // LRM שומר את סימן המינוס בצד שמאל של המספר גם בטקסט RTL
        return "\u{200E}\(sign)\(grouped) ₪"
    }

    /// מספר ללא סימן מטבע, לשדות עריכה: "1234.5"
    public static func editString(_ m: Money) -> String {
        let negative = m.minorUnits < 0
        let a = m.minorUnits.magnitude
        var s = String(a / 100)
        let ag = a % 100
        if ag != 0 { s += "." + (ag < 10 ? "0" : "") + String(ag) }
        return (negative ? "-" : "") + s
    }
}

// MARK: - פענוח סכומים מטקסט (Shortcuts, CSV, הקלדה)

public enum AmountParser {
    /// מפענח "₪45.90", "45,90", "1,234.50", "ILS 12", "(120.00)", "120.00-" ועוד.
    /// מחזיר nil אם אין ספרות.
    public static func parse(_ raw: String) -> Money? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        var negative = false
        if text.contains("-") || text.contains("\u{2212}") { negative = true }
        if text.hasPrefix("(") && text.hasSuffix(")") { negative = true }
        text = String(text.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") })
        guard text.contains(where: { $0.isNumber }) else { return nil }

        let lastDot = text.lastIndex(of: ".")
        let lastComma = text.lastIndex(of: ",")
        var decimalSep: Character? = nil
        switch (lastDot, lastComma) {
        case let (d?, c?):
            decimalSep = d > c ? "." : ","
        case (_?, nil):
            // נקודה אחת = נקודה עשרונית (הפורמט הישראלי); כמה נקודות = מפריד אלפים
            decimalSep = text.filter { $0 == "." }.count == 1 ? "." : nil
        case (nil, _?):
            let commas = text.filter { $0 == "," }.count
            if commas == 1, let c = lastComma {
                let after = text[text.index(after: c)...]
                decimalSep = (after.count == 1 || after.count == 2) ? "," : nil
            }
        default: break
        }

        var integerPart = ""
        var fractionPart = ""
        if let sep = decimalSep, let idx = text.lastIndex(of: sep) {
            integerPart = String(text[..<idx]).filter { $0.isNumber }
            fractionPart = String(text[text.index(after: idx)...]).filter { $0.isNumber }
        } else {
            integerPart = text.filter { $0.isNumber }
        }
        if integerPart.isEmpty { integerPart = "0" }
        guard integerPart.count <= 15, let whole = Int64(integerPart) else { return nil }

        var agorot: Int64 = 0
        if !fractionPart.isEmpty {
            let digits = Array(fractionPart)
            let first = Int64(String(digits[0])) ?? 0
            let second = digits.count > 1 ? (Int64(String(digits[1])) ?? 0) : 0
            agorot = first * 10 + second
            if digits.count > 2, let third = Int64(String(digits[2])), third >= 5 { agorot += 1 }
        }
        var minor = whole * 100 + agorot
        if negative { minor = -minor }
        return Money(minorUnits: minor)
    }
}
