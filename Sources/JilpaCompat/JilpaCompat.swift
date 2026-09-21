// JilpaCompat: compatibility bundle schema, Ed25519 signature check, atomic apply and rollback.
//
// May depend on: JilpaCore, CryptoKit.
//
// Data narrows, code broadens: a bundle can select among compiled strategies and exclude apps.
// Strategy names and signature predicates are closed enums, decoding is strict, and a rejected
// update never broadens the supported set.
//
// `CompatBundle` is the decoded document, `BundleVerifier` turns signed bytes into a
// `VerifiedBundle`, and `CompatStore` keeps the one in force, the one before it and the highest
// sequence ever applied. The network refresh and its off switch land with WP9; the trusted key
// and the bundle shipped inside the app are wired in JilpaApp.
