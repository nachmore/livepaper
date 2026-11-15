// PlistValue — an exact, value-typed copy of a property list, so the wallpaper store can be edited
// without losing anything LivePaper doesn't understand.
//
// PropertyListSerialization hands back Foundation objects whose types blur (a Bool is an NSNumber,
// equality treats 1 == true, reals compare with ==). The store editor needs the opposite: every
// field it doesn't edit must come back exactly as it was read. PlistValue keeps the plist type of
// each value, compares reals and dates bit for bit, and treats data blobs (the store's nested binary
// plists) as opaque bytes.
import CoreFoundation
import Foundation

public indirect enum PlistValue: Sendable, Hashable, CustomStringConvertible {
    case string(String)
    case integer(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    /// Thrown when a property list holds something PlistValue can't represent exactly.
    public struct UnsupportedValue: Error, LocalizedError, Sendable, Equatable {
        public var detail: String
        public var errorDescription: String? { "unsupported property-list value: \(detail)" }
    }

    // MARK: - Conversion

    /// Parses any property-list format (the wallpaper store is binary).
    public static func parse(_ data: Data) throws -> PlistValue {
        try PlistValue(foundation: PropertyListSerialization.propertyList(from: data, options: [], format: nil))
    }

    /// Converts the objects PropertyListSerialization returns. Booleans are told apart from numbers
    /// by their CoreFoundation type, so `true` never turns into `1`.
    public init(foundation object: Any) throws {
        switch object {
        case let string as String:
            self = .string(string)
        case let data as Data:
            self = .data(data)
        case let date as Date:
            self = .date(date)
        case let number as NSNumber:
            let cf = number as CFNumber
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(cf) {
                self = .real(number.doubleValue)
            } else if CFNumberGetType(cf).rawValue <= CFNumberType.maxType.rawValue {
                self = .integer(number.int64Value)
            } else {
                // 128-bit integers (binary plists can hold them) don't fit Int64.
                throw UnsupportedValue(detail: "integer \(number)")
            }
        case let array as [Any]:
            self = .array(try array.map { try PlistValue(foundation: $0) })
        case let dictionary as [String: Any]:
            self = .dictionary(try dictionary.mapValues { try PlistValue(foundation: $0) })
        default:
            throw UnsupportedValue(detail: String(describing: type(of: object)))
        }
    }

    /// The Foundation object graph PropertyListSerialization writes.
    public var foundationObject: Any {
        switch self {
        case .string(let s): return s as NSString
        case .integer(let i): return NSNumber(value: i)
        case .real(let d): return NSNumber(value: d)
        case .bool(let b): return NSNumber(value: b)   // the CFBoolean singletons
        case .date(let d): return d as NSDate
        case .data(let d): return d as NSData
        case .array(let a): return a.map(\.foundationObject) as NSArray
        case .dictionary(let m): return m.mapValues(\.foundationObject) as NSDictionary
        }
    }

    /// Serializes as a binary property list (the store's format).
    public func binaryData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: foundationObject, format: .binary, options: 0)
    }

    // MARK: - Access

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var dataValue: Data? { if case .data(let d) = self { return d }; return nil }
    public var dateValue: Date? { if case .date(let d) = self { return d }; return nil }
    public var arrayValue: [PlistValue]? { if case .array(let a) = self { return a }; return nil }
    public var dictionaryValue: [String: PlistValue]? { if case .dictionary(let m) = self { return m }; return nil }

    /// The value for `key` of a dictionary (nil for other kinds).
    public subscript(key: String) -> PlistValue? { dictionaryValue?[key] }

    /// The value at a path of dictionary keys.
    public func value(at path: [String]) -> PlistValue? {
        path.reduce(Optional(self)) { $0?[$1] }
    }

    /// A copy with the value at `path` (dictionary keys; every dictionary on the way must exist)
    /// replaced or added.
    public func setting(_ value: PlistValue, at path: [String]) throws -> PlistValue {
        guard let key = path.first else { return value }
        guard var dict = dictionaryValue else { throw UnsupportedValue(detail: "\(key) isn't inside a dictionary") }
        let rest = Array(path.dropFirst())
        if rest.isEmpty {
            dict[key] = value
        } else {
            guard let child = dict[key] else { throw UnsupportedValue(detail: "missing \(key)") }
            dict[key] = try child.setting(value, at: rest)
        }
        return .dictionary(dict)
    }

    /// Key paths at which `self` and `other` differ, as deep as both sides are dictionaries (an
    /// array or leaf that differs is reported at its own path). Empty when they are identical.
    public func differences(from other: PlistValue, at path: [String] = []) -> [[String]] {
        guard case .dictionary(let a) = self, case .dictionary(let b) = other else {
            return self == other ? [] : [path]
        }
        var result: [[String]] = []
        for key in Set(a.keys).union(b.keys).sorted() {
            switch (a[key], b[key]) {
            case let (x?, y?): result += x.differences(from: y, at: path + [key])
            case (nil, nil): break
            default: result.append(path + [key])
            }
        }
        return result
    }

    // MARK: - Exact equality

    public static func == (lhs: PlistValue, rhs: PlistValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.real(a), .real(b)): return a.bitPattern == b.bitPattern
        case let (.bool(a), .bool(b)): return a == b
        case let (.date(a), .date(b)): return a.timeIntervalSinceReferenceDate.bitPattern == b.timeIntervalSinceReferenceDate.bitPattern
        case let (.data(a), .data(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.dictionary(a), .dictionary(b)): return a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let s): hasher.combine(0); hasher.combine(s)
        case .integer(let i): hasher.combine(1); hasher.combine(i)
        case .real(let d): hasher.combine(2); hasher.combine(d.bitPattern)
        case .bool(let b): hasher.combine(3); hasher.combine(b)
        case .date(let d): hasher.combine(4); hasher.combine(d.timeIntervalSinceReferenceDate.bitPattern)
        case .data(let d): hasher.combine(5); hasher.combine(d)
        case .array(let a): hasher.combine(6); hasher.combine(a)
        case .dictionary(let m): hasher.combine(7); hasher.combine(m)
        }
    }

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .integer(let i): return "\(i)"
        case .real(let d): return "\(d)"
        case .bool(let b): return "\(b)"
        case .date(let d): return "\(d)"
        case .data(let d): return "<\(d.count) bytes>"
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .dictionary(let m): return "{" + m.keys.sorted().map { "\($0) = \(m[$0]!)" }.joined(separator: "; ") + "}"
        }
    }
}
