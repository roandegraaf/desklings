import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The longest side an image the owner sends is scaled down to. What a vision endpoint reads at
/// and what a chat bubble needs; anything larger is bytes the model call pays for twice.
nonisolated let MAX_IMAGE_SIDE = 1568
/// The daemon's own cap on one inline image, decoded.
nonisolated let MAX_IMAGE_BYTES = 5_000_000

/// An image as it goes on a message: scaled to fit `MAX_IMAGE_SIDE`, JPEG, base64. ImageIO reads
/// whatever the picker, the pasteboard or a file hands over — HEIC, PNG, TIFF — and turns the
/// orientation tag into pixels, so a phone photo arrives the way up it was taken. Nil for bytes
/// that are not an image, or one too large to send even after scaling.
nonisolated func inlineImage(from data: Data) -> Base64Image? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: MAX_IMAGE_SIDE,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let encoded = NSMutableData()
    guard let sink = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(sink), encoded.length <= MAX_IMAGE_BYTES else { return nil }
    return Base64Image(mediaType: "image/jpeg", base64: (encoded as Data).base64EncodedString())
}

/// Decoded straight to the pixels it is drawn at: a full-size PNG re-decoded on every redraw is
/// what makes a thread of screenshots stutter. `size` is the original's, for layout.
nonisolated func imageThumbnail(_ image: Base64Image, maxPixels: Int) -> (image: CGImage, size: CGSize)? {
    guard let data = Data(base64Encoded: image.base64),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0
    else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height)),
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          thumbnail.width > 0, thumbnail.height > 0
    else { return nil }
    let longest = CGFloat(max(width, height)) / CGFloat(max(thumbnail.width, thumbnail.height))
    return (thumbnail, CGSize(width: CGFloat(thumbnail.width) * longest, height: CGFloat(thumbnail.height) * longest))
}

/// On disk, because Quick Look, the pasteboard and a save all take a file. A folder per image keeps
/// the name plain for a save and makes opening it again overwrite rather than pile up.
nonisolated func imageFile(_ image: Base64Image) throws -> URL {
    guard let data = Data(base64Encoded: image.base64) else { throw CocoaError(.fileReadCorruptFile) }
    let ext = UTType(mimeType: image.mediaType)?.preferredFilenameExtension ?? "png"
    let folder = FileManager.default.temporaryDirectory.appending(path: "images-\(abs(image.base64.hashValue))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "Image.\(ext)")
    try data.write(to: url, options: .atomic)
    return url
}

/// Whether a picked file is an image by its extension, which is what decides between inline
/// and `~/uploads`.
nonisolated func isImageFile(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
}
