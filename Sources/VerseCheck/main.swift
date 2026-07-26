import Foundation

// Verse verification harness. Normally runs all spec-required checks and exits non-zero on
// failure. Two special subcommands drive the SIGKILL crash-injection test
// (scripts/crash-recovery-test.sh): `crash-writer <dir>` sets up unclean state and blocks to
// be killed; `crash-recover <dir>` verifies recovery afterward.

let argv = CommandLine.arguments
if argv.count >= 3, argv[1] == "crash-writer" { crashWriter(dir: argv[2]) }   // never returns
if argv.count >= 3, argv[1] == "crash-recover" { crashRecover(dir: argv[2]) } // exits

let tk = TestKit()
print("Verse checks\n============")
runModelChecks(tk)
runEngineChecks(tk)
runRecordingChecks(tk)
runPersistenceChecks(tk)
runTransportChecks(tk)
runMultitrackChecks(tk)
runPatchChecks(tk)
runUndoChecks(tk)
runAppStoreChecks(tk)
runAnalysisChecks(tk)
runPluginChecks(tk)
runHumToMIDIChecks(tk)
runMIDIChecks(tk)
runFuzzChecks(tk)
runUndoRoundTripChecks(tk)
runLayoutSelectionPropertyChecks(tk)
runPianoKeyboardLayoutChecks(tk)

tk.finish()
