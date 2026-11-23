import Foundation

/// רכישה נכנסת מאוטומציית Wallet (כל השדות אופציונליים — iOS לא תמיד מעביר הכול)
public struct IncomingPurchase: Sendable {
    public var amount: Money?
    public var merchant: String?
    public var cardLabel: String?
    public var externalID: String?
    public var receivedAt: Date
    public init(amount: Money?, merchant: String?, cardLabel: String?, externalID: String? = nil, receivedAt: Date) {
        self.amount = amount; self.merchant = merchant; self.cardLabel = cardLabel
        self.externalID = externalID; self.receivedAt = receivedAt
    }
    public var isComplete: Bool { amount.map { $0.isPositive } == true && !(merchant ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

public struct PurchaseCandidate: Sendable {
    public var id: UUID
    public var amount: Money?
    public var merchant: String?
    public var cardLabel: String?
    public var externalID: String?
    public var receivedAt: Date
    public init(id: UUID, amount: Money?, merchant: String?, cardLabel: String?, externalID: String?, receivedAt: Date) {
        self.id = id; self.amount = amount; self.merchant = merchant; self.cardLabel = cardLabel
        self.externalID = externalID; self.receivedAt = receivedAt
    }
}

public enum DuplicateVerdict: Equatable, Sendable {
    /// חדשה — ליצור
    case unique
    /// הפעלה חוזרת של אותה אוטומציה — לא ליצור
    case rerun(of: UUID)
    /// דומה לעסקה קיימת אבל ייתכן שאמיתית — ליצור עם סימון "ייתכן כפילות"
    case similar(to: UUID)
}

public enum DuplicateDetector {
    /// חלון הפעלה חוזרת (שניות)
    public static let rerunWindow: TimeInterval = 180
    /// חלון דמיון (שניות)
    public static let similarWindow: TimeInterval = 6 * 3600

    public static func normalize(_ s: String?) -> String {
        guard let s else { return "" }
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ").joined(separator: " ")
    }

    public static func check(_ incoming: IncomingPurchase, against existing: [PurchaseCandidate],
                             rerunWindow: TimeInterval = rerunWindow, similarWindow: TimeInterval = similarWindow) -> DuplicateVerdict {
        if let ext = incoming.externalID, !ext.isEmpty,
           let match = existing.first(where: { $0.externalID == ext }) {
            return .rerun(of: match.id)
        }
        let merchant = normalize(incoming.merchant)
        let card = normalize(incoming.cardLabel)
        var similar: UUID? = nil
        for c in existing.sorted(by: { $0.receivedAt > $1.receivedAt }) {
            let dt = Swift.abs(c.receivedAt.timeIntervalSince(incoming.receivedAt))
            guard dt <= similarWindow else { continue }
            let sameAmount = c.amount == incoming.amount
            let sameMerchant = normalize(c.merchant) == merchant
            let sameCard = card.isEmpty || normalize(c.cardLabel).isEmpty || normalize(c.cardLabel) == card
            guard sameAmount && sameMerchant && sameCard else { continue }
            if dt <= rerunWindow { return .rerun(of: c.id) }
            // רק רכישות מלאות יכולות להיות "דומות"; רכישות ריקות לא מסומנות כדי לא להציף
            if incoming.isComplete && similar == nil { similar = c.id }
        }
        if let similar { return .similar(to: similar) }
        return .unique
    }
}
