// swift-tools-version:5.9
// חבילה לבדיקת הלוגיקה הפיננסית בלבד (Kesef/Core) — רצה ב-`swift test` על Mac, וגם על Linux/Windows עם Swift.
// האפליקציה עצמה נבנית מ-Kesef.xcodeproj ומקמפלת את אותם קבצים ישירות.
import PackageDescription

let package = Package(
    name: "FinanceCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "FinanceCore", targets: ["FinanceCore"])],
    targets: [
        .target(name: "FinanceCore", path: "Kesef/Core"),
        .testTarget(name: "FinanceCoreTests", dependencies: ["FinanceCore"], path: "Tests/FinanceCoreTests")
    ]
)
