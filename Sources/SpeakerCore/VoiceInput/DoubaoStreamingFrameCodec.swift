import Foundation

package struct DoubaoStreamingFrame: Equatable, Sendable {
    package let messageType: UInt8
    package let flags: UInt8
    package let serialization: UInt8
    package let compression: UInt8
    package let sequence: Int32?
    package let errorCode: UInt32?
    package let payload: Data

    package var isFinal: Bool { flags & 0x02 != 0 }
}

package enum DoubaoStreamingFrameCodec {
    private static let versionAndHeaderSize: UInt8 = 0x11

    package static func fullClientRequest(payload: Data) -> Data {
        encode(
            messageType: 0x01,
            flags: 0x00,
            serialization: 0x01,
            compression: 0x00,
            payload: payload
        )
    }

    package static func audioRequest(payload: Data, isFinal: Bool) -> Data {
        encode(
            messageType: 0x02,
            flags: isFinal ? 0x02 : 0x00,
            serialization: 0x00,
            compression: 0x00,
            payload: payload
        )
    }

    package static func decode(_ data: Data) throws -> DoubaoStreamingFrame {
        guard data.count >= 8 else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
        let headerSize = Int(data[data.startIndex] & 0x0F) * 4
        guard headerSize >= 4, data.count >= headerSize + 4 else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }

        let typeAndFlags = data[data.startIndex + 1]
        let serializationAndCompression = data[data.startIndex + 2]
        let messageType = typeAndFlags >> 4
        let flags = typeAndFlags & 0x0F
        let serialization = serializationAndCompression >> 4
        let compression = serializationAndCompression & 0x0F
        var offset = headerSize
        var sequence: Int32?
        var errorCode: UInt32?

        if messageType == 0x09, flags & 0x01 != 0 {
            guard data.count >= offset + 4 else {
                throw DoubaoASRFailure(kind: .invalidResponse)
            }
            sequence = Int32(bitPattern: readUInt32(data, at: offset))
            offset += 4
        } else if messageType == 0x0F {
            guard data.count >= offset + 4 else {
                throw DoubaoASRFailure(kind: .invalidResponse)
            }
            errorCode = readUInt32(data, at: offset)
            offset += 4
        }

        guard data.count >= offset + 4 else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
        let payloadSize = Int(readUInt32(data, at: offset))
        offset += 4
        guard payloadSize >= 0, data.count >= offset + payloadSize else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
        guard compression == 0 else {
            throw DoubaoASRFailure(
                kind: .invalidResponse,
                message: "Unexpected compressed response"
            )
        }

        return DoubaoStreamingFrame(
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression,
            sequence: sequence,
            errorCode: errorCode,
            payload: data.subdata(in: offset..<(offset + payloadSize))
        )
    }

    private static func encode(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        payload: Data
    ) -> Data {
        var data = Data([
            versionAndHeaderSize,
            (messageType << 4) | flags,
            (serialization << 4) | compression,
            0x00,
        ])
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 24
            | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8
            | UInt32(data[start + 3])
    }
}
