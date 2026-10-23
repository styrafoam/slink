import AppKit

/// Draws the menu-bar spring icon.
enum SpringIcon {
    static func image() -> NSImage {
        let result = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            draw(in: bounds, ink: .black)
            return true
        }
        result.isTemplate = true
        return result
    }

    static func draw(in bounds: NSRect, ink: NSColor) {
        let wire = NSBezierPath()
        let origin = CGPoint(x: bounds.minX + bounds.width * 4 / 18,
                             y: bounds.minY + bounds.height * 4 / 18)
        let scaleX = bounds.width / 18, scaleY = bounds.height / 18
        let diagonal = sqrt(0.5)
        func location(_ fraction: Double) -> CGPoint {
            let turn = Double.pi * (0.5 + 6 * fraction)
            let narrowing = 1 - fraction / 10
            let side = 2.4 * cos(turn) * narrowing
            let depth = 1.6 * sin(turn) * narrowing
            return CGPoint(x: origin.x + (8.5 * fraction + diagonal * (depth - side)) * scaleX,
                           y: origin.y + (8.5 * fraction + diagonal * (depth + side)) * scaleY)
        }
        let beginning = location(0), ending = location(1)
        wire.move(to: CGPoint(x: beginning.x - 0.3 * scaleX, y: beginning.y - 0.15 * scaleY))
        for sample in 0...360 { wire.line(to: location(Double(sample) / 360)) }
        wire.line(to: CGPoint(x: ending.x + 0.3 * scaleX, y: ending.y + 0.15 * scaleY))
        wire.lineWidth = 0.95 * min(scaleX, scaleY)
        wire.lineCapStyle = .round
        wire.lineJoinStyle = .round
        ink.setStroke()
        wire.stroke()
    }
}
