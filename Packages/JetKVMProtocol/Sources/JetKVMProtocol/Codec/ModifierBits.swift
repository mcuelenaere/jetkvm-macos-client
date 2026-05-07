import Foundation

/// JetKVM keyboard modifier byte.
///
/// Bit layout — **NOT** the standard USB HID modifier byte. JetKVM
/// packs the same eight modifiers in a different order. Verified
/// against `ui/src/keyboardMappings.ts:256-266`, which is the
/// canonical browser-side layout that the device's gadget driver
/// expects.
///
/// | Bit  | Meaning             |
/// |------|---------------------|
/// | 0x01 | Left Control        |
/// | 0x02 | Left Shift          |
/// | 0x04 | Left Alt            |
/// | 0x08 | Left Meta (GUI/Cmd) |
/// | 0x10 | Right Control       |
/// | 0x20 | Right Shift         |
/// | 0x40 | Right Alt / AltGr   |
/// | 0x80 | Right Meta          |
///
/// Used as the modifier byte in `HIDRPCMessage.keyboardReport` and
/// echoed back from the host in `HIDRPCMessage.keydownState`.
public struct ModifierBits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let leftControl  = ModifierBits(rawValue: 0x01)
    public static let leftShift    = ModifierBits(rawValue: 0x02)
    public static let leftAlt      = ModifierBits(rawValue: 0x04)
    public static let leftMeta     = ModifierBits(rawValue: 0x08)
    public static let rightControl = ModifierBits(rawValue: 0x10)
    public static let rightShift   = ModifierBits(rawValue: 0x20)
    public static let rightAlt     = ModifierBits(rawValue: 0x40)
    public static let rightMeta    = ModifierBits(rawValue: 0x80)

    /// Either side of a modifier (e.g. `.anyControl` matches L_CTRL or R_CTRL).
    public static let anyControl: ModifierBits = [.leftControl, .rightControl]
    public static let anyShift:   ModifierBits = [.leftShift,   .rightShift]
    public static let anyAlt:     ModifierBits = [.leftAlt,     .rightAlt]
    public static let anyMeta:    ModifierBits = [.leftMeta,    .rightMeta]
}

/// USB HID boot-mouse button bitmask, used in
/// `HIDRPCMessage.pointerReport` and `HIDRPCMessage.mouseReport`.
///
/// | Bit  | Button       |
/// |------|--------------|
/// | 0x01 | Left         |
/// | 0x02 | Right        |
/// | 0x04 | Middle       |
/// | 0x08 | Back (X1)    |
/// | 0x10 | Forward (X2) |
///
/// The JetKVM gadget descriptor advertises buttons 1..5; bits 5..7 are
/// unused.
public struct MouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left    = MouseButtons(rawValue: 0x01)
    public static let right   = MouseButtons(rawValue: 0x02)
    public static let middle  = MouseButtons(rawValue: 0x04)
    public static let back    = MouseButtons(rawValue: 0x08)
    public static let forward = MouseButtons(rawValue: 0x10)
}
