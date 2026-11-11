import SwiftUI

/// Shown only in safe mode (Option held at launch, or two starts in a row that never got healthy).
struct SafeModeBanner: View {
    var body: some View {
        if SafeMode.isOn {
            Text(SafeMode.restored ? "Safe mode. Your saved layout was put back." : "Safe mode: add-ons are off.")
                .font(.footnote)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Space.s3).padding(.vertical, Theme.Space.s1)
                .background(Theme.verdictWarn.opacity(0.25), in: Capsule())
                .padding(.top, Theme.Space.s2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }
}
