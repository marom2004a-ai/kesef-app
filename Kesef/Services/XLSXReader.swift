import Foundation

/// קורא את הגיליון הראשון של קובץ Excel (.xlsx) לטבלת מחרוזות — בלי ספריות חיצוניות.
/// xlsx = ZIP של קובצי XML. פריסת ZIP נעשית כאן; פענוח DEFLATE דרך NSData.decompressed (zlib הגולמי של Apple).
enum XLSXReader {

    enum XLSXError: LocalizedError {
        case notZip, missingSheet, unsupportedCompression(Int), corrupt
        var errorDescription: String? {
            switch self {
            case .notZip: return "הקובץ אינו קובץ Excel תקין (xlsx)."
            case .missingSheet: return "לא נמצא גיליון בקובץ."
            case .unsupportedCompression(let m): return "שיטת דחיסה לא נתמכת בקובץ (\(m))."
            case .corrupt: return "הקובץ פגום."
            }
        }
    }

    static func readFirstSheet(_ data: Data) throws -> [[String]] {
        let files = try unzip(data, wanted: { $0 == "xl/sharedStrings.xml" || $0.hasPrefix("xl/worksheets/sheet") || $0 == "xl/workbook.xml" || $0 == "xl/_rels/workbook.xml.rels" })
        let shared = files["xl/sharedStrings.xml"].map(SharedStringsParser.parse) ?? []
        let sheetPath = firstSheetPath(workbook: files["xl/workbook.xml"], rels: files["xl/_rels/workbook.xml.rels"])
        guard let sheetData = files[sheetPath] ?? files["xl/worksheets/sheet1.xml"]
                ?? files.first(where: { $0.key.hasPrefix("xl/worksheets/sheet") })?.value else { throw XLSXError.missingSheet }
        return SheetParser.parse(sheetData, shared: shared)
    }

    // MARK: ZIP

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    static func unzip(_ data: Data, wanted: (String) -> Bool) throws -> [String: Data] {
        let d = Data(data)
        guard d.count > 22, u32(d, 0) == 0x04034b50 else { throw XLSXError.notZip }
        // End of central directory: מחפשים את החתימה מהסוף
        var eocd = -1
        var i = d.count - 22
        let stop = max(0, d.count - 22 - 65_535)
        while i >= stop { if u32(d, i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw XLSXError.corrupt }
        let count = u16(d, eocd + 10)
        var p = u32(d, eocd + 16)
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x02014b50 else { throw XLSXError.corrupt }
            let method = u16(d, p + 10)
            let compSize = u32(d, p + 20)
            let nameLen = u16(d, p + 28), extraLen = u16(d, p + 30), commentLen = u16(d, p + 32)
            let localOffset = u32(d, p + 42)
            let name = String(decoding: d[(d.startIndex + p + 46)..<(d.startIndex + p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard wanted(name) else { continue }
            guard localOffset + 30 <= d.count, u32(d, localOffset) == 0x04034b50 else { throw XLSXError.corrupt }
            let start = localOffset + 30 + u16(d, localOffset + 26) + u16(d, localOffset + 28)
            guard start + compSize <= d.count else { throw XLSXError.corrupt }
            let raw = d.subdata(in: (d.startIndex + start)..<(d.startIndex + start + compSize))
            switch method {
            case 0: result[name] = raw
            case 8: result[name] = try (raw as NSData).decompressed(using: .zlib) as Data
            default: throw XLSXError.unsupportedCompression(method)
            }
        }
        return result
    }

    private static func firstSheetPath(workbook: Data?, rels: Data?) -> String {
        guard let workbook, let rels,
              let wb = String(data: workbook, encoding: .utf8), let rl = String(data: rels, encoding: .utf8),
              let sheetTag = wb.range(of: "<sheet ").map({ wb[$0.lowerBound...] }),
              let ridRange = sheetTag.range(of: "r:id=\"") else { return "xl/worksheets/sheet1.xml" }
        let rid = sheetTag[ridRange.upperBound...].prefix { $0 != "\"" }
        guard let relRange = rl.range(of: "Id=\"\(rid)\"") else { return "xl/worksheets/sheet1.xml" }
        let relTagStart = rl[..<relRange.lowerBound].range(of: "<Relationship", options: .backwards)?.lowerBound ?? relRange.lowerBound
        let tag = rl[relTagStart...].prefix { $0 != ">" }
        guard let t = tag.range(of: "Target=\"") else { return "xl/worksheets/sheet1.xml" }
        var target = String(tag[t.upperBound...].prefix { $0 != "\"" })
        if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
        return target
    }

    // MARK: XML

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inSI = false, inT = false
        static func parse(_ data: Data) -> [String] {
            let p = SharedStringsParser(); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.strings
        }
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { inSI = true; current = "" } else if e == "t" && inSI { inT = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false } else if e == "si" { inSI = false; strings.append(current) }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [Int: [Int: String]] = [:]
        var rowIndex = 0, col = 0, nextCol = 0
        var type = "", value = "", inValue = false
        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let p = SheetParser(shared: shared); let x = XMLParser(data: data); x.delegate = p; x.parse()
            let maxRow = p.rows.keys.max() ?? -1
            let width = (p.rows.values.flatMap(\.keys).max() ?? -1) + 1
            guard maxRow >= 0, width > 0 else { return [] }
            return (0...maxRow).compactMap { r in
                guard let cells = p.rows[r] else { return nil }
                return (0..<width).map { cells[$0] ?? "" }
            }
        }

        static func columnIndex(_ ref: String) -> Int {
            var n = 0
            for ch in ref.unicodeScalars {
                guard ch.value >= 65 && ch.value <= 90 else { break }
                n = n * 26 + Int(ch.value - 64)
            }
            return n - 1
        }

        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row":
                rowIndex = (Int(a["r"] ?? "") ?? (rowIndex + 1)) - 1
                nextCol = 0
            case "c":
                col = a["r"].map(SheetParser.columnIndex) ?? nextCol
                if col < 0 { col = nextCol }
                nextCol = col + 1
                type = a["t"] ?? ""
                value = ""
            case "v", "t":
                inValue = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "v", "t": inValue = false
            case "c":
                var text = value
                if type == "s", let idx = Int(value), idx >= 0, idx < shared.count { text = shared[idx] }
                if type == "b" { text = value == "1" ? "TRUE" : "FALSE" }
                rows[rowIndex, default: [:]][col] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            default: break
            }
        }
    }
}
