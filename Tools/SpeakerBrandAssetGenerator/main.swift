import AppKit
import Foundation
import SpeakerAppFeatures
import SwiftUI

@main
struct SpeakerBrandAssetGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw GeneratorError(
                message: "usage: SpeakerBrandAssetGenerator <absolute-output-directory>"
            )
        }
        let outputPath = CommandLine.arguments[1]
        guard outputPath.hasPrefix("/") else {
            throw GeneratorError(message: "output directory must be absolute")
        }
        let outputDirectory = URL(
            fileURLWithPath: outputPath,
            isDirectory: true
        ).standardizedFileURL

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let iconset = outputDirectory.appendingPathComponent(
            "AppIcon.iconset",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: iconset,
            withIntermediateDirectories: true
        )

        let iconFiles: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for iconFile in iconFiles {
            try render(pixels: iconFile.pixels).write(
                to: iconset.appendingPathComponent(iconFile.name),
                options: .atomic
            )
        }
        let appIcon = try render(pixels: 1024)
        try appIcon.write(
            to: outputDirectory.appendingPathComponent("AppIcon.png"),
            options: .atomic
        )
        let icnsChunks: [(type: String, data: Data)] = try [
            ("icp4", render(pixels: 16)),
            ("icp5", render(pixels: 32)),
            ("ic07", render(pixels: 128)),
            ("ic08", render(pixels: 256)),
            ("ic09", render(pixels: 512)),
            ("ic10", appIcon),
            ("ic11", render(pixels: 32)),
            ("ic12", render(pixels: 64)),
            ("ic13", render(pixels: 256)),
            ("ic14", render(pixels: 512)),
        ]
        try encodeICNS(chunks: icnsChunks).write(
            to: outputDirectory.appendingPathComponent("AppIcon.icns"),
            options: .atomic
        )
    }

    @MainActor
    private static func render(pixels: Int) throws -> Data {
        let size = CGFloat(pixels)
        let renderer = ImageRenderer(content:
            SpeakerAppIconArtwork(size: size)
                .frame(width: size, height: size)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            throw GeneratorError(
                message: "could not render the \(pixels)-pixel Speaker icon"
            )
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GeneratorError(
                message: "could not encode the \(pixels)-pixel Speaker icon"
            )
        }
        return png
    }

    private static func encodeICNS(
        chunks: [(type: String, data: Data)]
    ) throws -> Data {
        for chunk in chunks where chunk.type.utf8.count != 4 {
            throw GeneratorError(message: "invalid ICNS chunk type: \(chunk.type)")
        }

        var tableOfContents = Data()
        for chunk in chunks {
            tableOfContents.append(contentsOf: chunk.type.utf8)
            tableOfContents.appendBigEndian(
                try encodedLength(payloadCount: chunk.data.count)
            )
        }

        let tableLength = try encodedLength(
            payloadCount: tableOfContents.count
        )
        let totalLength = 8 + Int(tableLength)
            + chunks.reduce(0) { partial, chunk in
                partial + 8 + chunk.data.count
            }
        guard let encodedTotalLength = UInt32(exactly: totalLength) else {
            throw GeneratorError(message: "generated ICNS file is too large")
        }

        var encoded = Data("icns".utf8)
        encoded.appendBigEndian(encodedTotalLength)
        encoded.append(contentsOf: "TOC ".utf8)
        encoded.appendBigEndian(tableLength)
        encoded.append(tableOfContents)
        for chunk in chunks {
            encoded.append(contentsOf: chunk.type.utf8)
            encoded.appendBigEndian(
                try encodedLength(payloadCount: chunk.data.count)
            )
            encoded.append(chunk.data)
        }
        return encoded
    }

    private static func encodedLength(payloadCount: Int) throws -> UInt32 {
        guard let length = UInt32(exactly: payloadCount + 8) else {
            throw GeneratorError(message: "generated ICNS chunk is too large")
        }
        return length
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private struct GeneratorError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
