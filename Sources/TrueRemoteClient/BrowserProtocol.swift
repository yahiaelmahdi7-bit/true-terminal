import Foundation
import CoreGraphics

/// The phone-browser wire format shared by the Mac server and the iPhone app.
/// Frames (Mac → phone) are binary: 4-byte big-endian header length, a JSON header, then the JPEG.
/// Everything else is a JSON text message.
public enum BrowserWire {
    public static func encodeFrame(header: [String: Any], jpeg: Data) -> Data {
        let h = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{}".utf8)
        var out = Data()
        var n = UInt32(h.count).bigEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(h); out.append(jpeg)
        return out
    }

    public static func decodeFrame(_ d: Data) -> (header: [String: Any], jpeg: Data)? {
        guard d.count >= 4 else { return nil }
        let b = [UInt8](d.prefix(4))
        let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard len >= 2, d.count >= 4 + len,
              let h = try? JSONSerialization.jsonObject(with: d.subdata(in: 4..<(4 + len))) as? [String: Any] else { return nil }
        return (h, d.subdata(in: (4 + len)..<d.count))
    }
}

/// Touch geometry. The phone shows the streamed page aspect-filled into its view, optionally pinch-zoomed
/// (`zoom` about the view centre, then shifted by `pan` points). Taps travel as normalized 0…1 page coordinates, so the
/// Mac never needs to know the phone's screen size or zoom.
public enum BrowserInputMapper {
    public static func normalized(point: CGPoint, viewSize: CGSize, zoom: CGFloat = 1, pan: CGPoint = .zero) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, zoom > 0 else { return .zero }
        let cx = viewSize.width / 2, cy = viewSize.height / 2
        let x = (point.x - cx - pan.x) / zoom + cx
        let y = (point.y - cy - pan.y) / zoom + cy
        return CGPoint(x: min(1, max(0, x / viewSize.width)), y: min(1, max(0, y / viewSize.height)))
    }

    /// Normalized → CSS pixels of the emulated viewport (what `Input.dispatch*` expects).
    public static func pagePoint(nx: Double, ny: Double, viewport: CGSize) -> CGPoint {
        CGPoint(x: (min(1, max(0, nx)) * viewport.width).rounded(), y: (min(1, max(0, ny)) * viewport.height).rounded())
    }

    /// Finger travel on the zoomed view → page scroll distance in CSS px (fingers move content, so the wheel goes the other way).
    public static func wheelDelta(fingerDelta: CGPoint, viewSize: CGSize, viewport: CGSize, zoom: CGFloat = 1) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, zoom > 0 else { return .zero }
        return CGPoint(x: -fingerDelta.x / zoom * viewport.width / viewSize.width,
                       y: -fingerDelta.y / zoom * viewport.height / viewSize.height)
    }
}
