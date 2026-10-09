import Foundation

/// Lossless JSON storage for decrypted subscription dictionaries, including
/// selectors added by relays that this build does not understand yet.
enum PushJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? value.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([Self].self) {
            self = .array(array)
        } else {
            self = try .object(value.decode([String: Self].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let bool): bool
        case .integer(let integer): integer
        case .number(let number): number
        case .string(let string): string
        case .array(let array): array.map(\.foundationValue)
        case .object(let object): object.mapValues(\.foundationValue)
        }
    }
}
