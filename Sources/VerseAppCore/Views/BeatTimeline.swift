import CoreGraphics
import VerseModel

/// Single source of truth for beats ↔ horizontal pixels on the arrangement and piano roll.
///
/// Both panes must share one scale and one horizontal scroll offset so a note at arrangement
/// beat 8 sits directly under whatever is at beat 8 in the lanes above. Do not duplicate
/// `beatWidth` or content-length math in the two views.
///
/// **Zoom** lives here only: both panes call the same `beatWidth(zoom:)` / `x(forBeat:zoom:)`
/// so arrangement and roll never drift. The live zoom value is stored on `AppStore.timelineZoom`.
public enum BeatTimeline {
    /// Pixels per beat at zoom 1.0. Historical default; all zoom math multiplies this.
    public static let baseBeatWidth: CGFloat = 28
    /// Left gutter for track controls (arrangement) / piano keys (roll). Shared so grid
    /// column 0 lines up. Wide enough for the compact always-visible track strip (AA1/AA2).
    public static let gutterWidth: CGFloat = 248
    /// Width of the drawn piano keys inside the roll's gutter column.
    ///
    /// The gutter column itself must stay `gutterWidth` so the roll's grid column 0 lines up
    /// with the arrangement's under the shared ruler and shared horizontal scroll. The keys,
    /// though, are a keyboard: drawn at the column's full 248pt they render as flat bars with
    /// no key proportions at all. They are drawn at this width, flush against the grid edge.
    public static let keyboardWidth: CGFloat = 72
    /// Height of the single shared beat ruler.
    public static let rulerHeight: CGFloat = 22

    public static let minZoom: Double = 0.25
    public static let maxZoom: Double = 8.0
    public static let defaultZoom: Double = 1.0
    /// Multiplicative step for zoom in / zoom out buttons.
    public static let zoomStep: Double = 1.25

    /// Pixels per beat at default zoom (1.0). Prefer `beatWidth(zoom:)` when zoom can vary.
    public static var beatWidth: CGFloat { beatWidth(zoom: defaultZoom) }

    /// Clamp a zoom factor into the supported range.
    public static func clampedZoom(_ zoom: Double) -> Double {
        min(maxZoom, max(minZoom, zoom))
    }

    /// Pixels per beat at the given zoom. Arrangement and roll must use the same zoom.
    public static func beatWidth(zoom: Double) -> CGFloat {
        baseBeatWidth * CGFloat(clampedZoom(zoom))
    }

    /// Horizontal pixel for an arrangement-absolute beat (beat 0 → x 0).
    public static func x(forBeat beat: Double, zoom: Double = defaultZoom) -> CGFloat {
        CGFloat(beat) * beatWidth(zoom: zoom)
    }

    /// Arrangement-absolute beat for a pixel x measured from the grid origin (beat 0).
    public static func beat(atX x: CGFloat, zoom: Double = defaultZoom) -> Double {
        Double(x / beatWidth(zoom: zoom))
    }

    /// Pixel width of a duration in beats.
    public static func width(forBeats beats: Double, zoom: Double = defaultZoom) -> CGFloat {
        CGFloat(beats) * beatWidth(zoom: zoom)
    }

    /// Zoom that fits `contentBeats` into `availableWidth` (caller subtracts the gutter).
    public static func fitZoom(contentBeats: Double, availableWidth: CGFloat) -> Double {
        guard contentBeats > 0, availableWidth > 0 else { return defaultZoom }
        let raw = Double(availableWidth) / (contentBeats * Double(baseBeatWidth))
        return clampedZoom(raw)
    }

    /// Next zoom after zooming in one step from `zoom`.
    public static func zoomedIn(from zoom: Double) -> Double {
        clampedZoom(zoom * zoomStep)
    }

    /// Next zoom after zooming out one step from `zoom`.
    public static func zoomedOut(from zoom: Double) -> Double {
        clampedZoom(zoom / zoomStep)
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
