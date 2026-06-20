import Foundation

// Verse verification harness. Runs all spec-required checks and exits non-zero on failure.
// Add new `runXChecks(tk)` calls here as modules land (AI fixtures, engine determinism,
// persistence/crash-recovery) so one `swift run VerseCheck` covers the whole spec.

let tk = TestKit()

print("Verse checks\n============")
runModelChecks(tk)
runEngineChecks(tk)
runRecordingChecks(tk)

tk.finish()
