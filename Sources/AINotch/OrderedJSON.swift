import Foundation

/// JSON that keeps its keys in file order and writes itself back the way Claude Code and Cursor
/// write their settings (`JSON.stringify(value, null, 2)`), so a file that goes through setup and
/// back is the same bytes. Numbers keep the text they were read as.
indirect enum OrderedJSON: Equatable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    struct Member: Equatable {
        var key: String
        var value: OrderedJSON
    }

    struct ParseError: Error, CustomStringConvertible {
        var offset: Int
        var description: String { "not valid JSON (at byte \(offset))" }
    }

    // MARK: Access

    var members: [Member]? { if case .object(let m) = self { return m } else { return nil } }
    var items: [OrderedJSON]? { if case .array(let a) = self { return a } else { return nil } }
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }

    /// An object's value by key; setting keeps the key where it is, or appends a new one; nil removes it.
    subscript(key: String) -> OrderedJSON? {
        get { members?.first { $0.key == key }?.value }
        set {
            guard case .object(var m) = self else { return }
            if let i = m.firstIndex(where: { $0.key == key }) {
                if let newValue { m[i].value = newValue } else { m.remove(at: i) }
            } else if let newValue {
                m.append(Member(key: key, value: newValue))
            }
            self = .object(m)
        }
    }

    /// Sets a key, putting a new one first rather than last.
    mutating func setFirst(_ key: String, _ value: OrderedJSON) {
        guard case .object(var m) = self else { return }
        if let i = m.firstIndex(where: { $0.key == key }) { m[i].value = value } else { m.insert(Member(key: key, value: value), at: 0) }
        self = .object(m)
    }

    static func int(_ n: Int) -> OrderedJSON { .number(String(n)) }

    // MARK: Writing

    /// `JSON.stringify(value, null, 2)`.
    func serialized() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.quote(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in a.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                item.write(into: &out, indent: indent + 1)
                out += i == a.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .object(let m):
            if m.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, member) in m.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                Self.quote(member.key, into: &out)
                out += ": "
                member.value.write(into: &out, indent: indent + 1)
                out += i == m.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Reading

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.i == parser.bytes.count else { throw ParseError(offset: parser.i) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            // A UTF-8 byte-order mark is allowed and dropped.
            self.bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        }

        func fail() -> ParseError { ParseError(offset: i) }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard i + lit.count <= bytes.count, Array(bytes[i..<i + lit.count]) == lit else { throw fail() }
            i += lit.count
        }

        mutating func value() throws -> OrderedJSON {
            guard i < bytes.count else { throw fail() }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var members: [Member] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail() }
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    members.append(Member(key: key, value: try value()))
                    skipSpace()
                    guard i < bytes.count else { throw fail() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    throw fail()
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value())
                    skipSpace()
                    guard i < bytes.count else { throw fail() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw fail()
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func number() throws -> String {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            func digits(_ p: inout Parser) -> Int {
                let s = p.i
                while p.i < p.bytes.count, (0x30...0x39).contains(p.bytes[p.i]) { p.i += 1 }
                return p.i - s
            }
            guard digits(&self) > 0 else { throw fail() }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digits(&self) > 0 else { throw fail() }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits(&self) > 0 else { throw fail() }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let n = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw fail() }
            i += 4
            return n
        }

        mutating func string() throws -> String {
            i += 1 // the opening quote
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw fail() }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                if b < 0x20 { throw fail() }
                if b != UInt8(ascii: "\\") { out.append(b); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw fail() }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail() }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw fail() }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail()
                }
            }
            guard let s = String(bytes: out, encoding: .utf8) else { throw fail() }
            return s
        }
    }
}
