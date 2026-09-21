// JilpaDialog: watcher, classifier, reader, signatures, session state.
//
// May depend on: JilpaCore, JilpaAX, JilpaCompat.
// Must not import: JilpaStore, JilpaUI.
//
// Turns raw AX notifications into dialog candidates, descriptors and snapshots. An unmatched
// window gets nothing.
//
// `WorkspaceApps` says which apps run, `DialogWatcher` keeps one observer per app it may
// observe and reports candidates, and `DialogClassifier` decides what a candidate is: stage
// one by role and identifier, then the structural stage over `PanelTree` snapshots.
// `DialogReader` reads a recognized dialog into a `DialogSnapshot`: folder, proposed name,
// selection, focus, view. All of it only reads, and none of it reads a window's title.
// `DialogSession` is the state of one dialog and the user-activity latch, a pure value type
// with no clock and no AX: `DialogCoordinator` in JilpaApp drives it and is its only writer.
// `jilpa-soak classify` runs the first three against FixtureApp and `jilpa-soak read` the
// reader.
