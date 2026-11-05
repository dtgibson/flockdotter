import Foundation

/// A bounded JSON parser retains number tokens and duplicate keys, avoiding NSNumber
/// boolean coercion and JSONDecoder's last-key-wins behavior at the trust boundary.
enum StrictCountJSON {
    indirect enum Value {
        case object([String: Value]), array([Value]), string(String), number(String), bool, null
    }

    static func decode(_ data: Data) throws -> CountDocument {
        guard data.count <= ResourceLimits.maxJSONBytes else {
            throw CountError.resource("Marker JSON must be no larger than 32 MiB.")
        }
        guard String(data: data, encoding: .utf8) != nil else { throw bad("The file is not readable UTF-8.") }
        var parser = Parser(bytes: Array(data))
        let root = try object(parser.parse())
        guard try string(root["format"]) == "dotcounter", try integer(root["version"]) == 1 else {
            throw CountError.unsupportedVersion
        }
        let image = try object(required(root["image"]))
        let identity = try ImageIdentity(
            sha256: string(image["sha256"]), pixelWidth: integer(image["pixelWidth"]),
            pixelHeight: integer(image["pixelHeight"]), originalFilename: string(image["originalFilename"]))
        guard case .array(let values) = try required(root["markers"]) else { throw bad("The markers field must be an array.") }
        guard values.count <= ResourceLimits.maxMarkers else { throw CountError.resource("A count can contain up to 100,000 markers.") }
        let markers = try values.map { value -> Marker in
            let entry = try object(value)
            guard let id = UUID(uuidString: try string(entry["id"])) else { throw bad("A marker identity is not a UUID.") }
            return try Marker(id: id, x: number(entry["x"]), y: number(entry["y"]))
        }
        return try CountDocument(image: identity, markers: markers).validated()
    }

    static func bad(_ message: String = "The JSON structure is invalid.") -> CountError { .invalid(message) }
    static func required(_ value: Value?) throws -> Value { guard let value else { throw bad("A required field is missing.") }; return value }
    static func object(_ value: Value) throws -> [String: Value] { guard case .object(let object) = value else { throw bad("An expected JSON object is missing.") }; return object }
    static func string(_ value: Value?) throws -> String { guard case .string(let string) = try required(value) else { throw bad("An expected text field has the wrong type.") }; return string }
    static func number(_ value: Value?) throws -> Double {
        guard case .number(let token) = try required(value), let result = Double(token), result.isFinite else { throw bad("An expected finite number has the wrong type.") }
        return result == 0 ? 0 : result
    }
    static func integer(_ value: Value?) throws -> Int {
        guard case .number(let token) = try required(value) else { throw bad("An expected integer has the wrong type.") }
        // Inspect decimal digits before converting. Rounding through Double would
        // incorrectly accept 1.0000000000000000001 or 5999.999999999999999999.
        let negative = token.hasPrefix("-")
        let unsigned = negative ? String(token.dropFirst()) : token
        let components = unsigned.split(whereSeparator: { $0 == "e" || $0 == "E" })
        let mantissa = String(components[0])
        let fraction = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.index(after: $0), to: mantissa.endIndex) } ?? 0
        var digits = mantissa.filter { $0 != "." }
        digits = String(digits.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        let exponent: Int
        if components.count == 2 {
            guard let parsed = Int(components[1]), (-1_000_000...1_000_000).contains(parsed) else { throw bad("An integer exponent is too large.") }
            exponent = parsed
        } else { exponent = 0 }
        let power = exponent - fraction
        if power < 0 {
            let requiredZeros = -power
            guard requiredZeros <= digits.count,
                  digits.suffix(requiredZeros).allSatisfy({ $0 == "0" }) else { throw bad("An expected integer contains a fraction.") }
            digits.removeLast(requiredZeros)
        } else {
            guard power <= 19, digits.count <= 19 - power else { throw bad("An integer is too large.") }
            digits += String(repeating: "0", count: power)
        }
        guard digits.count <= 19, let result = Int((negative ? "-" : "") + digits) else { throw bad("An integer is too large.") }
        return result
    }

    struct Parser {
        var bytes: [UInt8]
        var position = 0
        enum Context {
            case root, image, markers, marker, unknown
            var requiredKeys: Set<String> {
                switch self {
                case .root: ["format", "version", "image", "markers", "recoveryFormat", "recoveryVersion", "workspaceID", "revision", "sourceToken", "baselineDigest", "savedAt"]
                case .image: ["sha256", "pixelWidth", "pixelHeight", "originalFilename"]
                case .marker: ["id", "x", "y"]
                case .markers, .unknown: []
                }
            }
            func child(for key: String) -> Context {
                if case .root = self {
                    if key == "image" { return .image }
                    if key == "markers" { return .markers }
                }
                return .unknown
            }
        }

        mutating func parse() throws -> Value {
            let value = try value(depth: 0, context: .root)
            whitespace()
            guard position == bytes.count else { throw bad() }
            return value
        }
        mutating func whitespace() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }
        mutating func value(depth: Int, context: Context) throws -> Value {
            guard depth < 64 else { throw CountError.resource("The JSON is nested too deeply.") }
            whitespace()
            guard position < bytes.count else { throw bad() }
            switch bytes[position] {
            case 123:
                position += 1
                var values: [String: Value] = [:]
                if consume(125) { return .object(values) }
                repeat {
                    whitespace()
                    let key = try text()
                    guard consume(58) else { throw bad() }
                    let item = try value(depth: depth + 1, context: context.child(for: key))
                    if values[key] != nil && context.requiredKeys.contains(key) { throw bad("A required key occurs more than once.") }
                    values[key] = item
                    if consume(125) { return .object(values) }
                } while consume(44)
                throw bad()
            case 91:
                position += 1
                var values: [Value] = []
                if consume(93) { return .array(values) }
                repeat {
                    guard values.count < ResourceLimits.maxMarkers + 1 else { throw CountError.resource("The JSON array is too large.") }
                    values.append(try value(depth: depth + 1, context: context == .markers ? .marker : .unknown))
                    if consume(93) { return .array(values) }
                } while consume(44)
                throw bad()
            case 34: return .string(try text())
            case 116: try literal("true"); return .bool
            case 102: try literal("false"); return .bool
            case 110: try literal("null"); return .null
            case 45, 48...57: return .number(try numericToken())
            default: throw bad()
            }
        }
        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard bytes.count - position >= expected.count,
                  Array(bytes[position..<(position + expected.count)]) == expected else { throw bad() }
            position += expected.count
        }
        mutating func text() throws -> String {
            let start = position
            guard position < bytes.count, bytes[position] == 34 else { throw bad() }
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 {
                    let encoded = Data(bytes[start..<position])
                    guard let string = try? JSONDecoder().decode(String.self, from: encoded) else { throw bad("A text field has invalid escaping.") }
                    return string
                }
                if byte < 32 { throw bad() }
                if byte == 92 {
                    guard position < bytes.count else { throw bad() }
                    position += 1
                }
            }
            throw bad()
        }
        mutating func numericToken() throws -> String {
            let start = position
            if bytes[position] == 45 { position += 1 }
            guard position < bytes.count else { throw bad() }
            if bytes[position] == 48 { position += 1 }
            else {
                guard (49...57).contains(bytes[position]) else { throw bad() }
                while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
            }
            if position < bytes.count && bytes[position] == 46 {
                position += 1
                let digitStart = position
                while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
                guard position > digitStart else { throw bad() }
            }
            if position < bytes.count && [69, 101].contains(bytes[position]) {
                position += 1
                if position < bytes.count && [43, 45].contains(bytes[position]) { position += 1 }
                let digitStart = position
                while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
                guard position > digitStart else { throw bad() }
            }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }
    }
}

/// Syntax and duplicate-required-key preflight shared by public JSON and private
/// recovery. Typed model decoding and validation must follow this bounded pass.
public enum JSONValidation {
    public static func validateSyntax(_ data: Data) throws {
        guard data.count <= ResourceLimits.maxJSONBytes else { throw CountError.resource("JSON must be no larger than 32 MiB.") }
        guard String(data: data, encoding: .utf8) != nil else { throw CountError.invalid("The file is not readable UTF-8.") }
        var parser = StrictCountJSON.Parser(bytes: Array(data))
        _ = try parser.parse()
    }
}
