// JilpaCore: pure Swift. Model, Privacy, Rules, Predictor, Consent, Context, Outcome, Activity,
// Search, Diagnostics.
//
// May depend on: Foundation.
// Must not import: AppKit, ApplicationServices, GRDB.
//
// Everything here is Sendable values and pure functions, callable from anywhere; the two
// exceptions hold diagnostics in memory behind a lock (`LogRing`, `IntervalStats`). Inferred facts
// are `known(value, source)` or `unknown(reason)`; unknown never triggers automation and never
// trains. `Resolved`, the privacy gate, the consent gate, rule resolution, the frecency counter,
// dialog outcome inference, the save lifecycle, location identity and the state derived from a
// destination check (`LocationCheck`), the records the activity store keeps, the redaction
// every log line goes through (`LogMessage`), the log and signpost front ends with their closed
// lists of categories and names, and the diagnostics bundle as a value are here. The sinks over
// the system log and the system's signposts are in JilpaApp, so this module imports neither.
