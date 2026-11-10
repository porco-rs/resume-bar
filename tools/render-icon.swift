// SVG → .iconset (then `iconutil -c icns`). Extended with an
// optional second SVG for the small sizes (16 and 32 px pixels), where fine detail of the large drawing turns to mush.
// Usage: swift tools/render-icon.swift <icon.svg> [<icon-small.svg>] <out.iconset>
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4,
      let large = NSImage(contentsOfFile: args[1]) else { fatalError("Cannot read supplied icon SVG") }
let small = args.count == 4 ? NSImage(contentsOfFile: args[2]) ?? large : large
let output = URL(fileURLWithPath: args[args.count - 1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render icon") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    (size <= 32 ? small : large).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: output.appendingPathComponent(name)) }
}
