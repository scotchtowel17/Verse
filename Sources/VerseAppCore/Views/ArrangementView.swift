import CoreGraphics
import Foundation
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

// MARK: - Selection helpers (Step U1, testable)

/// Pure multi-clip selection helpers for the arrangement. Free of SwiftUI so VerseCheck can
/// lock marquee hit-testing, group-move rejection, paste offsets, and kind compatibility.
public enum ArrangementSelection {
    /// Whether a clip’s time × track-lane rectangle intersects the marquee.
    /// Track indices are inclusive. Time ranges touch if they overlap at all.
    public static func clipTouchesMarquee(
        startBeat: Double, lengthBeats: Double, trackIndex: Int,
        beatA: Double, beatB: Double,
        trackA: Int, trackB: Int
    ) -> Bool {
        let beatLo = min(beatA, beatB)
        let beatHi = max(beatA, beatB)
        let trackLo = min(trackA, trackB)
        let trackHi = max(trackA, trackB)
        let clipBeatHi = startBeat + lengthBeats
        let timeOverlap = startBeat < beatHi && clipBeatHi > beatLo
        let trackOverlap = trackIndex >= trackLo && trackIndex <= trackHi
        return timeOverlap && trackOverlap
    }

    /// IDs of clips whose blocks touch the marquee in beat/track space.
    public static func clipsTouchingMarquee(
        clips: [(id: UUID, startBeat: Double, lengthBeats: Double, trackIndex: Int)],
        beatA: Double, beatB: Double,
        trackA: Int, trackB: Int
    ) -> [UUID] {
        clips.filter {
            clipTouchesMarquee(
                startBeat: $0.startBeat, lengthBeats: $0.lengthBeats, trackIndex: $0.trackIndex,
                beatA: beatA, beatB: beatB, trackA: trackA, trackB: trackB)
        }.map(\.id)
    }

    /// Apply the same beat and track-index delta to every origin. Returns nil if any result
    /// would start before beat 0 or land outside `0..<trackCount` (whole group rejected).
    public static func applyGroupDelta(
        origins: [(startBeat: Double, trackIndex: Int)],
        beatDelta: Double,
        trackDelta: Int,
        trackCount: Int
    ) -> [(startBeat: Double, trackIndex: Int)]? {
        guard trackCount > 0 else { return nil }
        var result: [(startBeat: Double, trackIndex: Int)] = []
        result.reserveCapacity(origins.count)
        for o in origins {
            let s = o.startBeat + beatDelta
            let t = o.trackIndex + trackDelta
            guard s >= 0, t >= 0, t < trackCount else { return nil }
            result.append((startBeat: s, trackIndex: t))
        }
        return result
    }

    /// Paste starts: the earliest clipboard clip maps to `playheadBeat`; others keep relative
    /// offsets. Same contract as piano-roll paste (negative results are returned for the
    /// caller to reject with a readable message).
    public static func pasteStartBeats(
        clipboardStarts: [Double],
        playheadBeat: Double
    ) -> [Double] {
        guard let earliest = clipboardStarts.min() else { return [] }
        let delta = playheadBeat - earliest
        return clipboardStarts.map { $0 + delta }
    }

    /// Whether every placement is kind-compatible with its destination track.
    public static func placementsCompatible(
        clipKinds: [ClipKind],
        trackKinds: [TrackKind],
        trackIndices: [Int]
    ) -> Bool {
        guard clipKinds.count == trackIndices.count else { return false }
        for i in clipKinds.indices {
            let ti = trackIndices[i]
            guard trackKinds.indices.contains(ti) else { return false }
            if !Project.trackAccepts(clipKind: clipKinds[i], trackKind: trackKinds[ti]) {
                return false
            }
        }
        return true
    }
}
