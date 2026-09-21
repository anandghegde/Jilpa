// JilpaConfig: TOML model, merge, validation, directory watcher, atomic writer.
//
// May depend on: JilpaCore, TOMLKit.
// Must not import: AppKit.
//
// `config.toml` is hand-owned and never written. `managed.toml` is rewritten whole and
// atomically. A parse or validation error keeps the last valid model.
//
// `ConfigLoader.load` is the pure path from two texts to one `ConfigLoad`; `ConfigStore` is the
// files. TOMLKit types stop at `ConfigValue.parse`. `ConfigWatcher` reports changes and
// `ConfigState` keeps the last valid model and the one health notice.
