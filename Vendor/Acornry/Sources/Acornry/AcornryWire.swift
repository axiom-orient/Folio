import Foundation

package enum AcornryFrameKind: UInt16, Sendable {
  case hello = 1
  case offer = 2
  case decision = 3
  case chunk = 4
  case fileEnd = 5
  case transferEnd = 6
  case receipt = 7
  case cancel = 8
  case receiptQuery = 9
  case receiptUnavailable = 10
  case protocolError = 11
}

package struct AcornryFrame: Sendable, Equatable {
  package let kind: AcornryFrameKind
  package let payload: Data
}

package enum AcornryWire {
  package static let magic = Data([0x41, 0x43, 0x4E, 0x52])  // ACNR
  package static let protocolVersion: UInt16 = 1
  package static let headerByteCount = 12
  package static let chunkPrefixByteCount = 48

  package static func encode(_ frame: AcornryFrame, maxFrameBytes: Int) throws -> Data {
    guard frame.payload.count <= maxFrameBytes else {
      throw AcornryError.resourceLimitExceeded(
        "frame payload \(frame.payload.count) exceeds \(maxFrameBytes)")
    }
    var data = Data()
    data.reserveCapacity(headerByteCount + frame.payload.count)
    data.append(magic)
    appendUInt16(protocolVersion, to: &data)
    appendUInt16(frame.kind.rawValue, to: &data)
    appendUInt32(UInt32(frame.payload.count), to: &data)
    data.append(frame.payload)
    return data
  }

  package static func decodeHeader(_ data: Data, maxFrameBytes: Int) throws -> (
    AcornryFrameKind, Int
  ) {
    guard data.count == headerByteCount else {
      throw AcornryError.protocolViolation("invalid frame header length")
    }
    guard data.prefix(4) == magic else {
      throw AcornryError.protocolViolation("invalid frame magic")
    }
    let version = readUInt16(data, at: 4)
    guard version == protocolVersion else { throw AcornryError.unsupportedProtocol(version) }
    guard let kind = AcornryFrameKind(rawValue: readUInt16(data, at: 6)) else {
      throw AcornryError.protocolViolation("unknown frame kind")
    }
    let payloadLength = Int(readUInt32(data, at: 8))
    guard payloadLength <= maxFrameBytes else {
      throw AcornryError.resourceLimitExceeded(
        "frame payload \(payloadLength) exceeds \(maxFrameBytes)")
    }
    return (kind, payloadLength)
  }

  package static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  package static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw AcornryError.protocolViolation("invalid \(String(describing: type)) payload: \(error)")
    }
  }

  package static func encodeChunk(
    transferID: AcornryTransferID,
    fileIndex: Int,
    offset: Int64,
    bytes: Data
  ) throws -> Data {
    guard fileIndex >= 0, fileIndex <= Int(UInt32.max), offset >= 0 else {
      throw AcornryError.protocolViolation("invalid chunk coordinates")
    }
    let id = transferID.rawValue.uuidString.lowercased()
    guard id.utf8.count == 36 else { throw AcornryError.protocolViolation("invalid UUID encoding") }
    var data = Data(id.utf8)
    appendUInt32(UInt32(fileIndex), to: &data)
    appendUInt64(UInt64(offset), to: &data)
    data.append(bytes)
    return data
  }

  package static func decodeChunk(_ payload: Data) throws -> (AcornryTransferID, Int, Int64, Data) {
    guard payload.count >= chunkPrefixByteCount else {
      throw AcornryError.protocolViolation("short chunk frame")
    }
    let idData = payload.prefix(36)
    guard let idString = String(data: idData, encoding: .utf8),
      let uuid = UUID(uuidString: idString)
    else {
      throw AcornryError.protocolViolation("invalid chunk transfer id")
    }
    let fileIndex = Int(readUInt32(payload, at: 36))
    let offsetRaw = readUInt64(payload, at: 40)
    guard offsetRaw <= UInt64(Int64.max) else {
      throw AcornryError.protocolViolation("invalid chunk offset")
    }
    return (
      AcornryTransferID(rawValue: uuid), fileIndex, Int64(offsetRaw),
      Data(payload.dropFirst(chunkPrefixByteCount))
    )
  }

  private static func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }
  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }
  private static func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }
  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }
  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
      | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
  }
  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
    return value
  }
}

package struct AcornryHello: Codable, Equatable, Sendable {
  package let peer: AcornryIdentity
  package let protocolVersion: UInt16
}

package struct AcornryOffer: Codable, Equatable, Sendable {
  package let manifest: AcornryTransferManifest
}

package struct AcornryDecision: Codable, Equatable, Sendable {
  package let transferID: AcornryTransferID
  package let accepted: Bool
  package let reason: String?
}

package struct AcornryFileEnd: Codable, Equatable, Sendable {
  package let transferID: AcornryTransferID
  package let fileIndex: Int
  package let byteCount: Int64
  package let checksumSHA256: String
}

package struct AcornryTransferEnd: Codable, Equatable, Sendable {
  package let transferID: AcornryTransferID
}

package struct AcornryCancel: Codable, Equatable, Sendable {
  package let transferID: AcornryTransferID
  package let reason: String?
}

package struct AcornryReceiptQuery: Codable, Equatable, Sendable {
  package let transferID: AcornryTransferID
  package let expectedManifestDigestSHA256: String
}

package struct AcornryReceiptUnavailable: Codable, Equatable, Sendable {
  package let transferID: AcornryTransferID
}

package struct AcornryProtocolErrorPayload: Codable, Equatable, Sendable {
  package let code: String
  package let detail: String
}
