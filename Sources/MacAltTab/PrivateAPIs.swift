import AppKit
import ApplicationServices

// Fonctions non documentées d'Apple, les mêmes qu'utilise AltTab.
// Aucune ne demande l'enregistrement de l'écran : l'Accessibilité suffit.

/// Numéro de fenêtre (CGWindowID) d'un élément d'Accessibilité.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Fabrique un élément d'Accessibilité à partir de son identifiant interne.
/// Sert à retrouver les fenêtres des autres bureaux, que kAXWindows ne renvoie pas.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SkyLight {
    typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let setFront: SetFront? = sym("_SLPSSetFrontProcessWithOptions")
    static let postEvent: PostEvent? = sym("SLPSPostEventRecordTo")

    private static func sym<T>(_ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// Met une fenêtre précise au premier plan, même sur un autre bureau.
    static func focus(pid: pid_t, wid: CGWindowID) {
        var psn = ProcessSerialNumber()
        GetProcessForPID(pid, &psn)
        _ = setFront?(&psn, wid, 0x200) // kCPSUserGenerated
        // Rend la fenêtre « key » (même technique qu'AltTab).
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEvent?(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEvent?(&psn, &bytes)
    }
}

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    var windowID: CGWindowID? {
        var w: CGWindowID = 0
        return _AXUIElementGetWindow(self, &w) == .success && w != 0 ? w : nil
    }
}
