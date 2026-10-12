import AppKit

/// The progress dialog's throughput chart: progress fills left to right, the transfer speed
/// is plotted against progress, and a horizontal rule marks the current speed.
@MainActor
final class SpeedGraphView: NSView {
    private struct Sample {
        let fraction: Double
        let speed: Double
    }

    private var samples: [Sample] = []
    private var fraction: Double = 0

    var speedText: String? {
        didSet { if speedText != oldValue { needsDisplay = true } }
    }

    var isPaused = false {
        didSet { if isPaused != oldValue { needsDisplay = true } }
    }

    func record(fraction: Double, speed: Double?) {
        self.fraction = fraction
        if let speed, fraction > (samples.last?.fraction ?? -1) {
            samples.append(Sample(fraction: fraction, speed: speed))
        }
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let tint: NSColor = isPaused ? .systemYellow : .systemGreen

        NSColor.textBackgroundColor.setFill()
        frame.fill()

        // Completed portion.
        tint.withAlphaComponent(0.15).setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width * fraction, height: frame.height).fill()

        // Speed curve, scaled so the fastest sample reaches 80% of the height.
        let maxSpeed = samples.map(\.speed).max() ?? 0
        if maxSpeed > 0, let last = samples.last {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: frame.minX, y: frame.minY))
            for sample in samples {
                path.line(to: point(for: sample, in: frame, maxSpeed: maxSpeed))
            }
            path.line(to: NSPoint(x: frame.minX + frame.width * last.fraction, y: frame.minY))
            path.close()
            tint.withAlphaComponent(0.45).setFill()
            path.fill()
            tint.setStroke()
            path.lineWidth = 1
            path.stroke()

            // Current speed rule and label.
            let currentY = point(for: last, in: frame, maxSpeed: maxSpeed).y
            NSColor.labelColor.withAlphaComponent(0.6).setFill()
            NSRect(x: frame.minX, y: currentY, width: frame.width, height: 1).fill()
            drawLabel(at: currentY, in: frame)
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: frame).stroke()
    }

    private func point(for sample: Sample, in frame: NSRect, maxSpeed: Double) -> NSPoint {
        NSPoint(
            x: frame.minX + frame.width * sample.fraction,
            y: frame.minY + frame.height * 0.8 * sample.speed / maxSpeed
        )
    }

    private func drawLabel(at y: CGFloat, in frame: NSRect) {
        guard let speedText else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = speedText.size(withAttributes: attributes)
        let labelY = min(y + 2, frame.maxY - size.height - 2)
        speedText.draw(at: NSPoint(x: frame.maxX - size.width - 6, y: labelY), withAttributes: attributes)
    }
}
