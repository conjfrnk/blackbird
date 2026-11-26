import AppKit

/// AppKit applies a tab-group resize to a background tab only when it is next selected, so the frame is pushed to siblings.
enum TabFrameSync {

    /// Skips `front` (re-setting its frame would recurse through `windowDidResize`) and miniaturized windows.
    static func targets(front: NSWindow, frame: NSRect, groupWindows: [NSWindow]) -> [NSWindow] {
        groupWindows.filter { window in
            window !== front
                && !window.isMiniaturized
                && window.frame != frame
        }
    }
}
