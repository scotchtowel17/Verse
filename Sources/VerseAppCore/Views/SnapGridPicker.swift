import SwiftUI
import VerseModel

/// Compact snap control for arrangement and piano roll (Step Z2).
///
/// Menu style with Straight and Triplets sections keeps the control narrow so the
/// dense toolbars never deform or clip at realistic widths. Segmented buttons were
/// already overflowing before 1/32 and the three triplet values were added.
struct SnapGridPicker: View {
    @Binding var snapBeats: Double
    var showLabel: Bool = true
    var helpText: String

    var body: some View {
        HStack(spacing: 4) {
            if showLabel {
                Text("Snap")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Picker("Snap", selection: $snapBeats) {
                Text("Off").tag(SnapGrid.off)
                Section("Straight") {
                    Text("1/4").tag(SnapGrid.quarter)
                    Text("1/8").tag(SnapGrid.eighth)
                    Text("1/16").tag(SnapGrid.sixteenth)
                    Text("1/32").tag(SnapGrid.thirtySecond)
                }
                Section("Triplets") {
                    Text("1/4T").tag(SnapGrid.quarterTriplet)
                    Text("1/8T").tag(SnapGrid.eighthTriplet)
                    Text("1/16T").tag(SnapGrid.sixteenthTriplet)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(helpText)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}
