import SwiftUI

extension View {
    /// A control VoiceOver can name: its label, what it is showing (`value`) and whether it is on
    /// (`selected`, for a choice among several or a toggle that is not a Toggle).
    func ax(_ label: String, value: String? = nil, selected: Bool? = nil, hint: String? = nil) -> some View {
        self.accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(selected == true ? .isSelected : [])
            .accessibilityHint(hint ?? "")
    }

    /// An icon that only decorates the words beside it: VoiceOver skips it.
    func decorative() -> some View { accessibilityHidden(true) }
}
