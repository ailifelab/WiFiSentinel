import AppKit

/// Resolution-independent menu bar artwork. AppKit supplies the template tint.
enum StatusIcon {
    static let size = NSSize(width: 20, height: 20)
    static let accessibilityName = "WiFi 哨兵"

    static func makeImage() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / size.width,
                             yBy: rect.height / size.height)
            transform.concat()
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Open eyes stay distinct from the Wi-Fi arcs at 1× and 2×.
            let eyes = NSBezierPath()
            eyes.move(to: NSPoint(x: 2.5, y: 16))
            eyes.curve(to: NSPoint(x: 8.5, y: 15.6),
                       controlPoint1: NSPoint(x: 4, y: 18.6),
                       controlPoint2: NSPoint(x: 7.3, y: 18.3))
            eyes.curve(to: NSPoint(x: 2.5, y: 16),
                       controlPoint1: NSPoint(x: 7.2, y: 13.6),
                       controlPoint2: NSPoint(x: 4.2, y: 13.6))
            eyes.close()
            eyes.move(to: NSPoint(x: 17.5, y: 16))
            eyes.curve(to: NSPoint(x: 11.5, y: 15.6),
                       controlPoint1: NSPoint(x: 16, y: 18.6),
                       controlPoint2: NSPoint(x: 12.7, y: 18.3))
            eyes.curve(to: NSPoint(x: 17.5, y: 16),
                       controlPoint1: NSPoint(x: 12.8, y: 13.6),
                       controlPoint2: NSPoint(x: 15.8, y: 13.6))
            eyes.close()
            eyes.lineWidth = 1.15
            eyes.lineJoinStyle = .round
            eyes.stroke()
            for x in [5.9, 14.1] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.85, y: 14.9,
                                           width: 1.7, height: 2)).fill()
            }

            let signal = NSBezierPath()
            signal.move(to: NSPoint(x: 1.75, y: 9.1))
            signal.curve(to: NSPoint(x: 18.25, y: 9.1),
                         controlPoint1: NSPoint(x: 6, y: 13),
                         controlPoint2: NSPoint(x: 14, y: 13))
            signal.move(to: NSPoint(x: 4.65, y: 6.65))
            signal.curve(to: NSPoint(x: 15.35, y: 6.65),
                         controlPoint1: NSPoint(x: 7.6, y: 9.35),
                         controlPoint2: NSPoint(x: 12.4, y: 9.35))
            signal.move(to: NSPoint(x: 7.55, y: 4.25))
            signal.curve(to: NSPoint(x: 12.45, y: 4.25),
                         controlPoint1: NSPoint(x: 8.95, y: 5.55),
                         controlPoint2: NSPoint(x: 11.05, y: 5.55))
            signal.lineWidth = 1.5
            signal.lineCapStyle = .round
            signal.stroke()
            NSBezierPath(ovalIn: NSRect(x: 8.95, y: 0.9,
                                       width: 2.1, height: 2.1)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityName
        return image
    }
}
