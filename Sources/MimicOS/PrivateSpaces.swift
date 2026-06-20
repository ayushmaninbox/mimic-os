import Foundation
import CoreGraphics

/// Thin, defensive wrapper around the private CoreGraphics window-space (CGS)
/// API used to make another app's window appear on every Mission Control space.
///
/// These symbols are undocumented and resolved at runtime via `dlsym`, so if a
/// future macOS removes or renames them the calls simply no-op — pinning then
/// degrades gracefully to scrcpy's `--always-on-top` plus frame-locking.
enum PrivateSpaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetWindowTagsFn = @convention(c)
        (Int32, UnsafePointer<UInt32>, Int32, UnsafePointer<UInt64>, Int32) -> Void

    // symbols are already loaded into our address space; the handle and resolved
    // function pointers are immutable after init, so the unchecked annotation is
    // sound (they're only ever read).
    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? =
        dlopen(nil, RTLD_NOW)

    private static let mainConnection: MainConnectionFn? = {
        guard let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: MainConnectionFn.self)
    }()

    // CGSSetWindowTags / CGSClearWindowTags flip per-window CGS tags; tag bit
    // 0x800000000 (set on the high word) is the long-standing "show on all
    // spaces / sticky" bit.
    private static let setWindowTags: SetWindowTagsFn? = {
        guard let sym = dlsym(handle, "CGSSetWindowTags") else { return nil }
        return unsafeBitCast(sym, to: SetWindowTagsFn.self)
    }()

    private static let clearWindowTags: SetWindowTagsFn? = {
        guard let sym = dlsym(handle, "CGSClearWindowTags") else { return nil }
        return unsafeBitCast(sym, to: SetWindowTagsFn.self)
    }()

    /// The CGS "sticky" tag — keeps a window on every space.
    private static let stickyTag: UInt64 = 0x0000_0008_0000_0000

    /// Add or remove the sticky / all-spaces tag on a window by its CGWindowID.
    static func setWindowOnAllSpaces(_ windowID: CGWindowID, enabled: Bool) {
        guard let mainConnection,
              let setTags = setWindowTags,
              let clearTags = clearWindowTags else { return }
        let cid = mainConnection()
        let windows: [UInt32] = [UInt32(windowID)]
        let tags: [UInt64] = [stickyTag]
        windows.withUnsafeBufferPointer { winPtr in
            tags.withUnsafeBufferPointer { tagPtr in
                if enabled {
                    setTags(cid, winPtr.baseAddress!, 1, tagPtr.baseAddress!, 64)
                } else {
                    clearTags(cid, winPtr.baseAddress!, 1, tagPtr.baseAddress!, 64)
                }
            }
        }
    }
}
