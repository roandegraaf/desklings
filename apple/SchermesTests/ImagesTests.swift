import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Schermes

private func png(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let encoded = NSMutableData()
    let sink = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sink, context.makeImage()!, nil)
    CGImageDestinationFinalize(sink)
    return encoded as Data
}

private func size(of image: Base64Image) -> (Int, Int) {
    let data = Data(base64Encoded: image.base64)!
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    return (decoded.width, decoded.height)
}

@Test func aLargeImageIsScaledToTheLongestSideAndSentAsJpeg() {
    let image = inlineImage(from: png(width: 3136, height: 1568))!
    #expect(image.mediaType == "image/jpeg")
    #expect(size(of: image) == (1568, 784))
    #expect(Data(base64Encoded: image.base64)!.starts(with: [0xFF, 0xD8]), "JPEG magic")
}

@Test func aThumbnailIsDecodedAtTheDrawnSizeAndKeepsTheOriginalsForLayout() throws {
    let data = png(width: 1280, height: 800)
    let image = Base64Image(mediaType: "image/png", base64: data.base64EncodedString())
    let drawn = try #require(imageThumbnail(image, maxPixels: 480))
    #expect((drawn.image.width, drawn.image.height) == (480, 300))
    #expect(drawn.size == CGSize(width: 1280, height: 800))
    let small = try #require(imageThumbnail(image, maxPixels: 4000))
    #expect((small.image.width, small.image.height) == (1280, 800), "never scaled up")
    #expect(imageThumbnail(Base64Image(mediaType: "image/png", base64: "bm90IGFuIGltYWdl"), maxPixels: 480) == nil)
}

@Test func aSmallImageIsNotScaledUp() {
    let image = inlineImage(from: png(width: 300, height: 200))!
    #expect(size(of: image) == (300, 200))
}

@Test func bytesThatAreNotAnImageAreRefused() {
    #expect(inlineImage(from: Data("hello".utf8)) == nil)
    #expect(isImageFile(URL(fileURLWithPath: "/tmp/shot.PNG")))
    #expect(isImageFile(URL(fileURLWithPath: "/tmp/photo.heic")))
    #expect(!isImageFile(URL(fileURLWithPath: "/tmp/notes.txt")))
}

@Test func anImageIsWrittenToDiskUnderItsOwnExtension() throws {
    let bytes = png(width: 4, height: 4)
    let file = try imageFile(Base64Image(mediaType: "image/png", base64: bytes.base64EncodedString()))
    #expect(file.lastPathComponent == "Image.png")
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try imageFile(Base64Image(mediaType: "image/jpeg", base64: "")).pathExtension == "jpeg")
}
