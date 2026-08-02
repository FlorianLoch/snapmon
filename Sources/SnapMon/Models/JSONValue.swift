import Foundation

enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }

  var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else {
      return nil
    }

    return value
  }

  var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else {
      return nil
    }

    return value
  }

  var stringValue: String? {
    switch self {
    case .string(let value):
      return value
    case .number(let value):
      return String(value)
    case .bool(let value):
      return String(value)
    default:
      return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .number(let value):
      return value
    case .string(let value):
      return Double(value)
    default:
      return nil
    }
  }

  var intValue: Int? {
    doubleValue.map(Int.init)
  }

  var boolValue: Bool? {
    switch self {
    case .bool(let value):
      return value
    case .number(let value):
      return value != 0
    case .string(let value):
      return ["1", "true", "yes"].contains(value.lowercased())
    default:
      return nil
    }
  }

  subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  func value(at path: String...) -> JSONValue? {
    path.reduce(Optional(self)) { partial, key in
      partial?[key]
    }
  }
}
