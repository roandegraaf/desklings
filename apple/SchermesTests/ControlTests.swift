import CoreGraphics
import Foundation
import Testing
@testable import Schermes

/// The two pure pieces the desktop's input rests on: which keysym a key is, and where on the
/// screen a point in a letterboxed view actually is.

// MARK: - Who may write

@Test func unknownOwnershipIsViewOnlyRatherThanAssumedFree() {
    #expect(viewOnly(nil))
    #expect(viewOnly(false))
    #expect(!viewOnly(true))
}

// MARK: - Keysyms

@Test func lettersAndDigitsAreTheirOwnCodePoint() {
    #expect(Keysym.of("a") == 0x61)
    #expect(Keysym.of("A") == 0x41)
    #expect(Keysym.of("0") == 0x30)
    #expect(Keysym.of(" ") == 0x20)
    #expect(Keysym.of("/") == 0x2f)
    // Latin-1 reaches to 0xff and is still itself; above it takes the Unicode escape.
    #expect(Keysym.of("é") == 0xe9)
    #expect(Keysym.of("€") == 0x0100_20ac)
}

@Test func theKeysThatAreNotLettersHaveTheirOwnKeysyms() {
    #expect(Keysym.of("\n") == 0xff0d)
    #expect(Keysym.of("\r") == 0xff0d)
    #expect(Keysym.of("\t") == 0xff09)
    #expect(Keysym.of("\u{1b}") == 0xff1b)
    // AppKit calls the key beside Return "delete" and sends U+007F for it; X11 calls that
    // BackSpace, and reserves Delete for the forward one.
    #expect(Keysym.of("\u{7f}") == 0xff08)
    #expect(Keysym.of("\u{08}") == 0xff08)
}

@Test func appKitReportsArrowsAndFunctionKeysAsPrivateUseScalars() {
    #expect(Keysym.of("\u{f700}") == 0xff52) // Up.
    #expect(Keysym.of("\u{f701}") == 0xff54) // Down.
    #expect(Keysym.of("\u{f702}") == 0xff51) // Left.
    #expect(Keysym.of("\u{f703}") == 0xff53) // Right.
    #expect(Keysym.of("\u{f704}") == 0xffbe) // F1.
    #expect(Keysym.of("\u{f70f}") == 0xffc9) // F12.
    #expect(Keysym.of("\u{f728}") == 0xffff) // Forward delete.
    #expect(Keysym.of("\u{f729}") == 0xff50) // Home.
    #expect(Keysym.of("\u{f72d}") == 0xff56) // Page down.
}

@Test func uiKitKeysAreReadOffTheirHidUsage() {
    #expect(Keysym.hid(41) == 0xff1b) // Escape.
    #expect(Keysym.hid(79) == 0xff53) // Right arrow.
    #expect(Keysym.hid(80) == 0xff51) // Left arrow.
    #expect(Keysym.hid(81) == 0xff54) // Down arrow.
    #expect(Keysym.hid(82) == 0xff52) // Up arrow.
    #expect(Keysym.hid(58) == 0xffbe) // F1.
    #expect(Keysym.hid(69) == 0xffc9) // F12.

    // A key the text input system will deliver as text must not also be claimed here, or it is
    // typed twice: `a` is HID 4, Return is 40, Tab is 43, Backspace is 42.
    for usage in [4, 30, 40, 42, 43] { #expect(Keysym.hid(usage) == nil) }

    #expect(Keysym.isModifier(225)) // Left shift.
    #expect(Keysym.isModifier(231)) // Right command.
    #expect(!Keysym.isModifier(4))
}

@Test func functionKeysStopAtTwelve() {
    #expect(Keysym.function(1) == 0xffbe)
    #expect(Keysym.function(12) == 0xffc9)
    #expect(Keysym.function(0) == nil)
    #expect(Keysym.function(13) == nil)
}

// MARK: - The letterbox

/// A 1000x500 desktop in a 600x600 box fits to 600x300 with 150 points of bar above and below.
private let wide = CGSize(width: 1000, height: 500)
private let square = CGSize(width: 600, height: 600)

@Test func aPointIsMappedThroughTheLetterboxAndNotThroughTheViewsOwnBounds() {
    #expect(framebufferPoint(CGPoint(x: 0, y: 150), view: square, screen: wide)! == (0, 0))
    #expect(framebufferPoint(CGPoint(x: 300, y: 300), view: square, screen: wide)! == (500, 250))
    // The far corner is the last pixel, not one past it.
    #expect(framebufferPoint(CGPoint(x: 599.9, y: 449.9), view: square, screen: wide)! == (999, 499))
}

@Test func aPressOnTheBarsIsNotAPressOnTheDesktop() {
    #expect(framebufferPoint(CGPoint(x: 300, y: 149), view: square, screen: wide) == nil)
    #expect(framebufferPoint(CGPoint(x: 300, y: 450), view: square, screen: wide) == nil)
    #expect(framebufferPoint(CGPoint(x: -1, y: 300), view: square, screen: wide) == nil)
    #expect(framebufferPoint(CGPoint(x: 601, y: 300), view: square, screen: wide) == nil)
}

@Test func aTallBoxPutsTheBarsAtTheSidesInstead() {
    // A 500x1000 desktop in a 600x600 box fits to 300x600, leaving 150 points either side.
    let tall = CGSize(width: 500, height: 1000)
    #expect(framebufferPoint(CGPoint(x: 150, y: 0), view: square, screen: tall)! == (0, 0))
    #expect(framebufferPoint(CGPoint(x: 300, y: 300), view: square, screen: tall)! == (250, 500))
    #expect(framebufferPoint(CGPoint(x: 149, y: 300), view: square, screen: tall) == nil)
}

@Test func aBoxWithNoAreaMapsNothingRatherThanDividingByZero() {
    #expect(framebufferPoint(.zero, view: .zero, screen: wide) == nil)
    #expect(framebufferPoint(.zero, view: square, screen: .zero) == nil)
}
