import Foundation

/// X11 keysyms, which is what an RFB `KeyEvent` carries. Xvnc looks a keysym up in its own keymap
/// and presses whatever keycode produces it, synthesising Shift itself where the keysym needs it,
/// so a capital letter is the keysym for the capital letter and not Shift plus the small one.
nonisolated enum Keysym {
    static let backSpace: UInt32 = 0xff08
    static let tab: UInt32 = 0xff09
    static let enter: UInt32 = 0xff0d
    static let escape: UInt32 = 0xff1b
    static let home: UInt32 = 0xff50
    static let left: UInt32 = 0xff51
    static let up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54
    static let pageUp: UInt32 = 0xff55
    static let pageDown: UInt32 = 0xff56
    static let end: UInt32 = 0xff57
    static let insert: UInt32 = 0xff63
    static let shift: UInt32 = 0xffe1
    static let control: UInt32 = 0xffe3
    /// `Alt_L`, and `Super_L` for Command: a Mac keyboard's Command sits where a PC's Super does,
    /// and mapping it to Alt would make every Cmd chord fire the desktop's Alt shortcut instead.
    /// The editing chords in `controlShortcut` are the exception, and go as Control.
    static let alt: UInt32 = 0xffe9
    static let meta: UInt32 = 0xffeb
    static let delete: UInt32 = 0xffff
    static let v: UInt32 = 0x76

    /// Copy, paste, cut, select all and undo (redo with Shift) are Command on a Mac and Control on
    /// the agent's Linux desktop, so those five Command chords are sent as Control ones; every other
    /// Command chord stays a Super chord. With Shift held the capital is sent, because Xvnc
    /// presses or lifts Shift itself to match the keysym it is given, and a small z under a held
    /// Shift would come out as undo rather than redo.
    static func controlShortcut(_ character: Character, shift: Bool) -> UInt32? {
        let letter = Character(character.lowercased())
        guard ["c", "v", "x", "a", "z"].contains(letter) else { return nil }
        return of(shift ? Character(letter.uppercased()) : letter)
    }

    static func isPaste(_ keysym: UInt32) -> Bool {
        keysym == v || keysym == 0x56
    }

    private static let firstFunction: UInt32 = 0xffbe

    static func function(_ number: Int) -> UInt32? {
        (1...12).contains(number) ? firstFunction + UInt32(number - 1) : nil
    }

    /// A character typed into the desktop. Latin-1 is its own code point — that is what the bottom
    /// of the keysym range is — and everything above it takes the Unicode escape X11 defines for
    /// exactly this. Control characters are the ones a keyboard sends as named keys instead.
    static func of(_ character: Character) -> UInt32? {
        switch character {
        case "\n", "\r": return enter
        case "\t": return tab
        case "\u{08}", "\u{7f}": return backSpace
        case "\u{1b}": return escape
        default: break
        }
        if let named = appKitFunctionKeys[character] { return named }
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar.value >= 0x20 else { return nil }
        return scalar.value <= 0xff ? scalar.value : 0x01000000 + scalar.value
    }

    /// AppKit reports arrows, function keys and the navigation cluster as private-use scalars in
    /// `charactersIgnoringModifiers` rather than as a separate code, so they are read off the same
    /// character the letters come from.
    private static let appKitFunctionKeys: [Character: UInt32] = {
        var table: [Character: UInt32] = [
            "\u{f700}": up, "\u{f701}": down, "\u{f702}": left, "\u{f703}": right,
            "\u{f727}": insert, "\u{f728}": delete, "\u{f729}": home, "\u{f72b}": end,
            "\u{f72c}": pageUp, "\u{f72d}": pageDown,
        ]
        for number in 1...12 {
            table[Character(Unicode.Scalar(0xf703 + UInt32(number))!)] = firstFunction + UInt32(number - 1)
        }
        return table
    }()

    /// The USB HID usage a `UIKey` carries, for the keys UIKit will not hand to `insertText`.
    /// Letters and digits are deliberately absent: those arrive as text, and a key that is both
    /// would be typed twice.
    static func hid(_ usage: Int) -> UInt32? {
        switch usage {
        case 41: escape
        case 73: insert
        case 74: home
        case 75: pageUp
        case 76: delete
        case 77: end
        case 78: pageDown
        case 79: right
        case 80: left
        case 81: down
        case 82: up
        case 58...69: firstFunction + UInt32(usage - 58)
        default: nil
        }
    }

    /// Whether a HID usage is a modifier key, which is pressed around a chord rather than sent on
    /// its own: UIKit reports the modifiers of the key that was pressed, so a chord is built from
    /// those and a bare modifier press has nothing to say.
    static func isModifier(_ usage: Int) -> Bool {
        (224...231).contains(usage)
    }
}
