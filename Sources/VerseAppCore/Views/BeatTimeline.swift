import CoreGraphics
import VerseModel

/// Single source of truth for beats ↔ horizontal pixels on the arrangement and piano roll.
///
/// Both panes must share one scale and one horizontal scroll offset so a note at arrangement
/// beat 8 sits directly under whatever is at beat 8 in the lanes above. Do not duplicate
/// `beatWidth` or content-length math in the two views.
public enum BeatTimeline {
    /// Pixels per beat. Shared by arrangement lanes and the piano-roll grid.
    public static let beatWidth: CGFloat = 28
    /// Left gutter for track names / piano keys. Shared so grid column 0 lines up.
    public static let gutterWidth: CGFloat = 100
    /// Height of the single shared beat ruler.
    public static let rulerHeight: CGFloat = 22

    /// Horizontal pixel for an arrangement-absolute beat (beat 0 → x 0).
    public static func x(forBeat beat: Double) -> CGFloat {
        CGFloat(beat) * beatWidth
    }

    /// Arrangement-absolute beat for a pixel x measured from the grid origin (beat 0).
    public static func beat(atX x: CGFloat) -> Double {
        Double(x / beatWidth)
    }

    /// Pixel width of a duration in beats.
    public static func width(forBeats beats: Double) -> CGFloat {
        CGFloat(beats) * beatWidth
    }

    /// Arrangement-absolute start beat of a clip-local note.
    public static func absoluteStart(clipStart: Double, noteLocalStart: Double) -> Double {
        clipStart + noteLocalStart
    }

    /// Clip-local beat from an arrangement-absolute beat (may be negative if before the clip).
    public static func localBeat(absolute: Double, clipStart: Double) -> Double {
        absolute - clipStart
    }

    /// Shared horizontal content length in beats for the workspace.
    ///
    /// Covers arrangement clips (via `ArrangementLayout.contentBeats`) and, when a MIDI clip
    /// is open in the roll, that clip’s end and any note that extends past it.
    public static func contentBeats(
        tracks: [Track],
        beatsPerBar: Int,
        openClip: Clip? = nil
    ) -> Double {
        let base = ArrangementLayout.contentBeats(tracks: tracks, beatsPerBar: beatsPerBar)
        guard let clip = openClip, clip.kind == .midi else { return base }
        let clipEnd = clip.startBeat + clip.lengthBeats
        let notes = clip.midiNotes ?? []
        let noteEnd = notes
            .map { note -> Double in
                absoluteStart(clipStart: clip.startBeat,
                              noteLocalStart: note.startBeat + note.lengthBeats)
            }
            .max() ?? 0
        return max(base, clipEnd, noteEnd)
    }
}
