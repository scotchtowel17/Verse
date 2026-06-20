import SwiftUI

/// A simple horizontal level meter (0…1), green→yellow→red, with a smooth fill.
struct MeterBar: View {
    var level: Float          // 0…1
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level)))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: height)
    }
}
