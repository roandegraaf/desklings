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

/// Random pixels, so the PNG does not compress to nothing.
private func noisyPng(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    for index in 0..<(context.bytesPerRow * height) { bytes[index] = UInt8.random(in: 0...255) }
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

@Test func theSizeIsReadFromTheHeaderAlone() {
    let tall = Base64Image(mediaType: "image/png", base64: png(width: 640, height: 1024).base64EncodedString())
    #expect(imageSize(tall) == CGSize(width: 640, height: 1024))
    let jpeg = inlineImage(from: png(width: 900, height: 300))!
    #expect(imageSize(jpeg) == CGSize(width: 900, height: 300))
    let big = Base64Image(mediaType: "image/png", base64: noisyPng(width: 400, height: 300).base64EncodedString())
    #expect(big.base64.utf8.count > 131_072, "larger than the head that is read")
    #expect(imageSize(big) == CGSize(width: 400, height: 300))
    #expect(imageSize(Base64Image(mediaType: "image/png", base64: "bm90IGFuIGltYWdl")) == nil)
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
