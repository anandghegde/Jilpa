// JilpaNavigator: strategies, steps, SafetyGuard, arrival verification, history.
//
// May depend on: JilpaCore, JilpaAX, JilpaDialog.
// Must not import: JilpaStore, JilpaUI.
//
// The only code that may change a dialog's folder. Input hierarchy, in strict order: an AX
// attribute or action on a specific element, then a key chord posted to the host pid. Never the
// global HID stream, synthesized mouse input or a path typed as keystrokes. Code lands with WP2,
// from the S2 spike results.
