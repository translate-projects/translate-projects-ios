import Foundation

/** Any JSON value; keeps booleans and numbers apart, which JSONSerialization does not on Linux. */
public enum JSON: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSON]), array([JSON]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }

    public subscript(key: String) -> JSON? {
        get { if case .object(let o) = self { return o[key] } else { return nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }

    /**
     * Xcode's own layout (sorted keys, `" : "`, two spaces), so saving from Xcode does not rewrite the whole file.
     * Also the canonical form used to compare what Xcode saved with what we wrote.
     */
    public func serialized(_ indent: String = "") -> String {
        switch self {
        case .string(let s): return JSON.quote(s)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a):
            if a.isEmpty { return "[\n\n\(indent)]" }
            let inner = indent + "  "
            return "[\n" + a.map { inner + $0.serialized(inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let o):
            if o.isEmpty { return "{\n\n\(indent)}" }
            let inner = indent + "  "
            return "{\n" + o.keys.sorted().map { inner + JSON.quote($0) + " : " + o[$0]!.serialized(inner) }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
