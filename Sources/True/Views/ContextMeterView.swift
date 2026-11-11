import SwiftUI

/// A thin bar on a seat line; the percent only shows from 90%, when it matters. Draws nothing when the model's context size is unknown (`reading` nil).
/// Monochrome: the fill gets brighter as the window fills, never a colour.
struct ContextMeterView: View {
    let reading: ContextReading?

    static let barWidth: CGFloat = 32

    var body: some View {
        if let r = reading {
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Token.line)
                    Capsule().fill(r.showsPercent ? Theme.Token.text0 : Theme.Token.text2).frame(width: Self.barWidth * r.fraction)
                }
                .frame(width: Self.barWidth, height: 3)
                if r.showsPercent {
                    Text(r.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context \(r.label) full")
        }
    }
}
