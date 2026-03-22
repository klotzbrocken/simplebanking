import AppKit

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage {
        let img = NSImage(size: newSize)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1.0)
        img.unlockFocus()
        return img
    }
}
