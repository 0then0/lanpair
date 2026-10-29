import AppKit
import Foundation
for path in CommandLine.arguments.dropFirst() {
    guard let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))), let input = source.bitmapData else { fatalError("Invalid icon") }
    guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 24), let bytes = output.bitmapData else { fatalError("Allocation failed") }
    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide {
            let src = y * source.bytesPerRow + x * source.samplesPerPixel
            let dst = y * output.bytesPerRow + x * 3
            bytes[dst] = input[src]; bytes[dst+1] = input[src+1]; bytes[dst+2] = input[src+2]
        }
    }
    try output.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
