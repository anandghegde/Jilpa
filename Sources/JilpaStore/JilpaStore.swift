// JilpaStore: GRDB schema, migrations, queries, retention, erase, export.
//
// May depend on: JilpaCore, GRDB.
// Must not import: AppKit.
//
// Write APIs accept only `Cleared<Record>` minted by the PrivacyGate, so bypassing the gate is a
// compile error, and each write checks that the record was cleared for that very operation.
// Every read goes back through the gate's `filter`, so an exclusion added after a row was stored
// still suppresses it; there is no unfiltered read. The records themselves are plain values in
// JilpaCore (Activity); `Stored` is the only place that knows how they map to SQL.
//
// Here now: schema v1, dialog sessions, destination counters, the identities of configured
// folders, retention, erase and the JSON export. The writers for `shadow_rank`, `nav_attempt`,
// `consent` and `save_outcome` land with the work packages that produce those rows.
