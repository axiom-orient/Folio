import AppKit
import ImageIO
import SwiftUI

/// Export the app's editable book-and-bookmark mark for both platform icon formats.
@main struct RenderFolioAssets {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw CocoaError(.fileNoSuchFile)
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let macMaster = try renderMaster(rounded: true)
    let iosMaster = try makeOpaque(renderMaster(rounded: false))

    let iconset = root.appendingPathComponent(DevelopmentIconLayout.iconsetName, isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in DevelopmentIconLayout.rasterSizes {
      let raster = try downsample(macMaster, to: size)
      try writePNG(raster, to: root.appendingPathComponent(DevelopmentIconLayout.rasterFilename(size: size)))
      for name in DevelopmentIconLayout.iconsetFilenames(size: size) {
        try writePNG(raster, to: iconset.appendingPathComponent(name))
      }
    }
    try writePNG(iosMaster, to: root.appendingPathComponent(DevelopmentIconLayout.iosFilename))
  }

  @MainActor private static func renderMaster(rounded: Bool) throws -> CGImage {
    let background = Color(red: 37 / 255, green: 66 / 255, blue: 54 / 255)
    let renderer = ImageRenderer(content: ZStack {
      if rounded {
        RoundedRectangle(cornerRadius: 190, style: .continuous)
          .fill(background).padding(80)
      } else {
        Rectangle().fill(background)
      }
      FolioBrandMark()
        .foregroundStyle(Color(red: 244 / 255, green: 240 / 255, blue: 228 / 255))
        .frame(width: 704, height: 440)
    }.frame(width: 1024, height: 1024))
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    return image
  }

  private static func makeOpaque(_ image: CGImage) throws -> CGImage {
    guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
      bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    guard let opaque = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return opaque
  }

  private static func downsample(_ image: CGImage, to size: Int) throws -> CGImage {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return output
  }

  private static func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
  }
}
