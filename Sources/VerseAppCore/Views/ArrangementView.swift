import CoreGraphics
import VerseModel

// Arrangement lane UI lives in TimelineWorkspaceView (ArrangementLanesView) so the
// arrangement and piano roll share one horizontal scroll and one BeatTimeline mapping.

// MARK: - Layout (testable)

/// Pure layout helpers for the arrangement timeline. Kept free of SwiftUI so VerseCheck
/// can lock the proportional resize-handle contract without rendering.
public enum ArrangementLayout {
    /// Max pixel width of the right-edge resize handle on a clip block.
    public static let resizeHandleMaxWidth: CGFloat = 10
    /// Fraction of clip width used for resize when the clip is shorter than the fixed max.
    public static let resizeHandleFraction: CGFloat = 0.3
    /// Minimum timeline length in bars when the project is empty or short.
    public static let minimumBars: Int = 4

    /// Resize hit zone for a clip of the given pixel width.
    ///
    /// Fixed-width handles cover the whole block on short clips, so every short clip became
    /// unmovable. Cap the zone at 30% of clip width so the body always moves.
    public static func resizeHandleWidth(clipWidth: CGFloat) -> CGFloat {
        guard clipWidth > 0 else { return 0 }
        return min(resizeHandleMaxWidth, clipWidth * resizeHandleFraction)
    }

    /// Round `beats` to the snap grid. `snapBeats == 0` means Off: return the value unchanged.
    public static func snap(_ beats: Double, to snapBeats: Double) -> Double {
        guard snapBeats > 0 else { return beats }
        return (beats / snapBeats).rounded() * snapBeats
    }

    /// Horizontal content length in beats: max of 4 bars, any clip end, plus one bar of pad.
    public static func contentBeats(tracks: [Track], beatsPerBar: Int) -> Double {
        let bpb = max(1, beatsPerBar)
        let fourBars = Double(bpb * minimumBars)
        let clipEnd = tracks.flatMap(\.clips)
            .map { $0.startBeat + $0.lengthBeats }
            .max() ?? 0
        // One bar of empty tail so the last clip is not flush against the edge.
        return max(fourBars, clipEnd + Double(bpb), 4)
    }
}
