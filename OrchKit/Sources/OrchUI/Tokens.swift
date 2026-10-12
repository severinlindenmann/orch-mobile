import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Nonisolated: UIKit resolves dynamic colours on arbitrary threads (a MainActor closure traps at runtime).
private nonisolated func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    #if canImport(UIKit)
    return Color(uiColor: UIColor { traits in
        let value = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    })
    #elseif canImport(AppKit)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    })
    #endif
}

@MainActor
public enum OC {                           // colours, resolved against the current system appearance
  // Orbit palette. Dark values are the orch-core dashboard tokens; light values are the approved iPhone refresh draft, with the brand/status text colours darkened a step so chip labels reach 4.5:1 on their 14% tint.
  public static let bg         = dyn(0xF3F5F7, 0x0E1014)
  public static let surface    = dyn(0xFFFFFF, 0x15181D)
  public static let surface2   = dyn(0xEEF1F4, 0x1C2027)
  public static let surface3   = dyn(0xE3E8ED, 0x242A32)
  public static let line       = dyn(0xDDE2E8, 0x2A3038)
  public static let lineStrong = dyn(0xC3CBD4, 0x3A424D)
  public static let text       = dyn(0x14181D, 0xE8EAED)
  public static let textMuted  = dyn(0x4D5864, 0x9AA3AD)
  public static let textFaint  = dyn(0x5F6B77, 0x8B949E)
  public static let brand      = dyn(0x096A54, 0x2FC6A3)   // the one action colour: actions, links, focus, Live dot
  public static let onBrand    = dyn(0xFFFFFF, 0x06231C)
  public static let you        = brand                     // "needs you" is the brand call to action, not a second hue
  public static let youMark    = brand
  public static let hosted     = dyn(0x9F430A, 0xF07A2E)   // client-hosted / addon orange: hosted context only
  public static let ok         = dyn(0x126530, 0x4ADE80)
  public static let warn       = dyn(0x7A4E08, 0xFBBF24)
  public static let danger     = dyn(0xB52626, 0xF87171)   // alarm, destructive
  public static let info       = dyn(0x1B58B5, 0x60A5FA)   // the primary's cert code frame
  public static let onDanger   = dyn(0xFFFFFF, 0x2A0A07)
  public static let demo       = info                      // demo stripe and chip (blue, no second brand hue)
  public static let markRing   = dyn(0x14181D, 0xE8EAED)
  public static let markEdge   = dyn(0xFFFFFF, 0x0A0C0F)
  public static func soft(_ c: Color) -> Color { c.opacity(0.14) }   // chip backgrounds (dashboard *-soft)
  // Workspace hues (share extension target list only; the app no longer draws colour bars).
  public static let wsHues: [Color] = [dyn(0x0B7F65,0x2FC6A3), dyn(0x0369A1,0x38BDF8), dyn(0x4338CA,0x818CF8),
                                dyn(0x4D7C0F,0xA3E635), dyn(0x8A6A3B,0xD6B98C), dyn(0x475569,0x94A3B8)]
}
public enum OF {                           // type: system styles only, so Dynamic Type works
  public static let display   = Font.largeTitle.weight(.bold)
  public static let wsName    = Font.title3.weight(.semibold)
  public static let section   = Font.headline
  public static let body      = Font.body
  public static let meta      = Font.footnote.weight(.medium).monospacedDigit()
  public static let machine   = Font.callout.monospaced()                       // sign-sheet text, ids, hashes
  public static let code      = Font.system(.largeTitle, design: .monospaced).weight(.semibold)   // SAS, cert code
}
public enum OS { public static let s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 20.0, s6 = 24.0, s8 = 32.0 }
public enum OR { public static let card = 14.0, control = 10.0, chip = 999.0, rail = 4.0 }  // .continuous corners
public enum OM {                           // motion
  public static let standard = Animation.snappy(duration: 0.25, extraBounce: 0)     // no bounce; the dashboard caps at 200 ms
  public static let reveal   = Animation.easeOut(duration: 0.2)     // codes: crossfade only, never slide
  // Reduce Motion: opacity only. Security surfaces (pairing codes, alarm, sign sheet) never animate content.
}

public extension OM {
    /// Apply this to non-security reveals; security content must not animate.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reveal : standard
    }
}
