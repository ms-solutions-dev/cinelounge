import AppKit
// svg-rasterize <in.svg> <out.png> <edge> — SVG with alpha channel onto a square PNG.
let args = CommandLine.arguments
guard args.count == 4, let edge = Int(args[3]),
    let image = NSImage(contentsOf: URL(fileURLWithPath: args[1]))
else { fputs("svg-rasterize <in.svg> <out.png> <edge>\n", stderr); exit(2) }
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
