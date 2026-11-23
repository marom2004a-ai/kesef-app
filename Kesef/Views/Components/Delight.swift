import SwiftUI
import Observation

// MARK: - אריח ניווט

/// אריח גדול עם אייקון זהב — לקיצורים במסכי הרכזת
struct HubTile<Destination: View>: View {
    var title: String
    var symbol: String
    var subtitle: String? = nil
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink { destination() } label: {
            HubTileLabel(title: title, symbol: symbol, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}

struct HubTileLabel: View {
    var title: String
    var symbol: String
    var subtitle: String? = nil
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(highlighted ? Theme.onGold : Theme.gold)
                .frame(width: 38, height: 38)
                .background(highlighted ? Theme.onGold.opacity(0.12) : Theme.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                .foregroundStyle(highlighted ? Theme.onGold : .primary)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(highlighted ? Theme.onGold.opacity(0.75) : Theme.mutedText).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(highlighted ? Theme.gold : Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline.opacity(highlighted ? 0 : 0.6), lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}

// MARK: - הכלב המלווה

/// כלב מצויר שמשנה הבעה לפי מצב הכסף
struct DogCompanionView: View {
    var mood: CompanionMood
    var size: CGFloat = 56
    @State private var bob = false

    private let fur = Color(red: 0.85, green: 0.63, blue: 0.40)
    private let ear = Color(red: 0.54, green: 0.35, blue: 0.17)
    private let ink = Color(red: 0.07, green: 0.067, blue: 0.063)

    var body: some View {
        let s = size
        ZStack {
            // אוזניים — בהתראה אחת מורמת
            Ellipse().fill(ear).frame(width: s * 0.30, height: s * 0.48)
                .rotationEffect(.degrees(mood == .alert ? -40 : 18), anchor: .top)
                .offset(x: -s * 0.33, y: -s * 0.08)
            Ellipse().fill(ear).frame(width: s * 0.30, height: s * 0.48)
                .rotationEffect(.degrees(-18), anchor: .top)
                .offset(x: s * 0.33, y: -s * 0.08)
            // ראש
            Circle().fill(fur).frame(width: s * 0.74, height: s * 0.74).offset(y: s * 0.05)
            // לוע
            Ellipse().fill(Color(red: 0.96, green: 0.84, blue: 0.68)).frame(width: s * 0.40, height: s * 0.28).offset(y: s * 0.20)
            eyes(s)
            // אף
            Ellipse().fill(ink).frame(width: s * 0.14, height: s * 0.10).offset(y: s * 0.13)
            mouth(s)
            if mood == .proud {
                Image(systemName: "sparkle").font(.system(size: s * 0.22, weight: .bold)).foregroundStyle(Theme.goldBright)
                    .offset(x: s * 0.42, y: -s * 0.36)
            }
        }
        .frame(width: s, height: s)
        .offset(y: bob ? -s * 0.03 : s * 0.02)
        .rotationEffect(.degrees(bob ? -3 : 3))
        .animation(.easeInOut(duration: mood == .alert ? 0.6 : 1.4).repeatForever(autoreverses: true), value: bob)
        .onAppear { bob = true }
        .accessibilityLabel("הכלב המלווה")
    }

    @ViewBuilder private func eyes(_ s: CGFloat) -> some View {
        switch mood {
        case .happy, .proud:
            // עיניים מחייכות ^ ^
            HStack(spacing: s * 0.16) {
                EyeArc().stroke(ink, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round)).frame(width: s * 0.12, height: s * 0.06)
                EyeArc().stroke(ink, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round)).frame(width: s * 0.12, height: s * 0.06)
            }
            .offset(y: -s * 0.04)
        case .alert:
            HStack(spacing: s * 0.15) {
                Circle().fill(ink).frame(width: s * 0.12)
                Circle().fill(ink).frame(width: s * 0.12)
            }
            .overlay(HStack(spacing: s * 0.21) { Circle().fill(.white).frame(width: s * 0.04); Circle().fill(.white).frame(width: s * 0.04) }.offset(x: -s * 0.015, y: -s * 0.02))
            .offset(y: -s * 0.03)
        case .calm:
            HStack(spacing: s * 0.17) {
                Circle().fill(ink).frame(width: s * 0.09)
                Circle().fill(ink).frame(width: s * 0.09)
            }
            .offset(y: -s * 0.03)
        }
    }

    @ViewBuilder private func mouth(_ s: CGFloat) -> some View {
        switch mood {
        case .happy, .proud:
            ZStack {
                Capsule().fill(Color(red: 0.93, green: 0.45, blue: 0.50)).frame(width: s * 0.10, height: s * 0.12).offset(y: s * 0.05)
                Smile().stroke(ink, style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round)).frame(width: s * 0.22, height: s * 0.07)
            }
            .offset(y: s * 0.22)
        case .alert:
            Ellipse().fill(ink).frame(width: s * 0.07, height: s * 0.08).offset(y: s * 0.25)
        case .calm:
            Smile().stroke(ink, style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round)).frame(width: s * 0.16, height: s * 0.04).offset(y: s * 0.23)
        }
    }
}

private struct Smile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 2))
        return p
    }
}

private struct EyeArc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        return p
    }
}

/// הכלב עם בועת דיבור
struct CompanionCard: View {
    var message: CompanionMessage

    var body: some View {
        HStack(spacing: 12) {
            DogCompanionView(mood: message.mood, size: 54)
            Text(message.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            Image(systemName: "chevron.left").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedText)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5))
        .animation(.snappy, value: message)
    }
}

// MARK: - חגיגות

/// מרכז החגיגות: כל חגיגה קורית פעם אחת למפתח (למשל "receipts-2026-11")
@Observable
@MainActor
final class Celebrations {
    static let shared = Celebrations()
    private(set) var trigger = 0
    private(set) var message: String?

    private let storeKey = "celebratedKeys"

    func celebrate(_ key: String, message: String) {
        var done = Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
        guard !done.contains(key) else { return }
        done.insert(key)
        UserDefaults.standard.set(Array(done.suffix(200)), forKey: storeKey)
        self.message = message
        trigger += 1
        let current = trigger
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            if self.trigger == current { self.message = nil }
        }
    }
}

/// קונפטי בזהב וצבעים חמים, מצויר ב-Canvas (בלי ספריות)
struct ConfettiView: View {
    var trigger: Int
    @State private var start: Date?
    @State private var pieces: [Piece] = []

    struct Piece {
        var x: Double; var vx: Double; var vy: Double; var spin: Double; var size: Double; var color: Color; var round: Bool
    }

    private static let colors: [Color] = [Theme.gold, Theme.goldBright, Theme.income, Theme.expense, .white]
    private let duration = 2.8

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { ctx in
            Canvas { g, size in
                guard let start else { return }
                let t = ctx.date.timeIntervalSince(start)
                guard t < duration else { return }
                let fade = max(0, 1 - max(0, t - duration + 0.8) / 0.8)
                for p in pieces {
                    let x = (p.x + p.vx * t) * size.width
                    let y = -20 + p.vy * t * size.height + 0.55 * t * t * size.height
                    var piece = g
                    piece.opacity = fade
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(p.spin * t))
                    let r = CGRect(x: -p.size / 2, y: -p.size / 3, width: p.size, height: p.size * (p.round ? 1 : 0.6))
                    piece.fill(p.round ? Path(ellipseIn: r) : Path(r), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: trigger) { _, _ in burst() }
    }

    private func burst() {
        pieces = (0..<90).map { _ in
            Piece(x: .random(in: 0.05...0.95), vx: .random(in: -0.12...0.12), vy: .random(in: 0.05...0.35),
                  spin: .random(in: -9...9), size: .random(in: 6...11), color: Self.colors.randomElement()!, round: Bool.random())
        }
        start = .now
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.1))
            start = nil
        }
    }
}

/// שכבת החגיגה: קונפטי + הודעה + רטט
struct CelebrationOverlay: View {
    @State private var center = Celebrations.shared

    var body: some View {
        ZStack(alignment: .top) {
            ConfettiView(trigger: center.trigger)
            if let msg = center.message {
                HStack(spacing: 10) {
                    DogCompanionView(mood: .proud, size: 34)
                    Text(msg).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onGold)
                }
                .padding(.vertical, 10).padding(.horizontal, 16)
                .background(Theme.gold, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45), value: center.message)
        .sensoryFeedback(.success, trigger: center.trigger)
        .allowsHitTesting(false)
    }
}
