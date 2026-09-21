// swift-tools-version: 6.2
import PackageDescription

// The target graph below is the layering table in docs/ARCHITECTURE.md. SwiftPM enforces the
// declared edges; Scripts/lint-imports.sh enforces the forbidden imports SwiftPM cannot see
// (AppKit is importable from any macOS target, and undeclared sibling modules can resolve by
// accident because they share a build directory).
//
// Third-party dependencies are capped at three (GRDB, TOMLKit, Sparkle 2). TOMLKit and GRDB are
// declared; Sparkle arrives with WP9. GRDB links the system SQLite. Versions are pinned exactly:
// this app holds the Accessibility permission, so an update is a reviewed change to this file.

let settings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "Jilpa",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "jilpa", targets: ["JilpaCLI"]),
    .executable(name: "JilpaAgent", targets: ["JilpaAgent"]),
    .executable(name: "FixtureApp", targets: ["FixtureApp"]),
    .executable(name: "jilpa-soak", targets: ["JilpaSoak"]),
  ],
  dependencies: [
    .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
  ],
  targets: [
    // Pure core and data
    .target(name: "JilpaCore", swiftSettings: settings),
    .target(
      name: "JilpaConfig",
      dependencies: ["JilpaCore", .product(name: "TOMLKit", package: "TOMLKit")],
      swiftSettings: settings
    ),
    .target(
      name: "JilpaStore",
      dependencies: ["JilpaCore", .product(name: "GRDB", package: "GRDB.swift")],
      swiftSettings: settings
    ),
    .target(name: "JilpaCompat", dependencies: ["JilpaCore"], swiftSettings: settings),
    .target(name: "JilpaIPC", swiftSettings: settings),

    // OS edges
    .target(name: "JilpaAX", swiftSettings: settings),
    .target(
      name: "JilpaDialog",
      dependencies: ["JilpaCore", "JilpaAX", "JilpaCompat"],
      swiftSettings: settings
    ),
    .target(
      name: "JilpaNavigator",
      // Compat because the compatibility cell is what names the strategy and its two waits;
      // the Navigator reads those off the descriptor and may add nothing to them.
      dependencies: ["JilpaCore", "JilpaAX", "JilpaCompat", "JilpaDialog"],
      swiftSettings: settings
    ),
    .target(name: "JilpaSensors", dependencies: ["JilpaCore", "JilpaAX"], swiftSettings: settings),

    // UI and composition root
    .target(name: "JilpaUI", dependencies: ["JilpaCore"], swiftSettings: settings),
    .target(
      name: "JilpaApp",
      dependencies: [
        "JilpaCore", "JilpaConfig", "JilpaStore", "JilpaCompat", "JilpaIPC",
        "JilpaAX", "JilpaDialog", "JilpaNavigator", "JilpaSensors", "JilpaUI",
      ],
      swiftSettings: settings
    ),

    // Thin app executable. Scripts/make-app.sh wraps it into Jilpa.app.
    .executableTarget(
      name: "JilpaAgent",
      dependencies: ["JilpaApp"],
      path: "App",
      exclude: ["Info.plist", "Jilpa.entitlements"],
      swiftSettings: settings
    ),

    // Tools
    .executableTarget(
      name: "JilpaCLI",
      dependencies: ["JilpaIPC"],
      path: "Tools/jilpa-cli",
      swiftSettings: settings
    ),
    .executableTarget(name: "FixtureApp", path: "Tools/FixtureApp", swiftSettings: settings),
    // The maintainer's signing tool for compatibility data. It is not shipped.
    .executableTarget(
      name: "compat-sign",
      dependencies: ["JilpaCompat"],
      path: "Tools/compat-sign",
      swiftSettings: settings
    ),
    // The compute budgets (ranking, Quick Search) on synthetic data. Run from a release build.
    .executableTarget(
      name: "jilpa-bench",
      dependencies: ["JilpaCore"],
      path: "Tools/bench",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "JilpaSoak",
      dependencies: [
        "JilpaApp", "JilpaAX", "JilpaDialog", "JilpaNavigator", "JilpaCompat", "JilpaCore",
        "JilpaUI",
      ],
      path: "Tools/soak",
      swiftSettings: settings
    ),

    // Spikes. Throwaway: deleted once the write-up under docs/spikes is accepted.
    .executableTarget(
      name: "s1-classify",
      dependencies: ["JilpaAX"],
      path: "Tools/spikes/s1-classify",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s0-logger",
      dependencies: ["JilpaAX"],
      path: "Tools/spikes/s0-logger",
      exclude: ["Info.plist"],
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s3a-reader",
      dependencies: ["JilpaAX"],
      path: "Tools/spikes/s3a-reader",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s8-destinations",
      path: "Tools/spikes/s8-destinations",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s3b-handoff",
      dependencies: ["JilpaAX"],
      path: "Tools/spikes/s3b-handoff",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s6-recorder",
      path: "Tools/spikes/s6-recorder",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s5-devcontext",
      path: "Tools/spikes/s5-devcontext",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s7-private",
      dependencies: ["JilpaAX"],
      path: "Tools/spikes/s7-private",
      swiftSettings: settings
    ),
    .executableTarget(
      name: "s4-hittest",
      path: "Tools/spikes/s4-hittest",
      swiftSettings: settings
    ),

    // Tests
    .testTarget(name: "JilpaCoreTests", dependencies: ["JilpaCore"], swiftSettings: settings),
    .testTarget(name: "JilpaConfigTests", dependencies: ["JilpaConfig"], swiftSettings: settings),
    .testTarget(
      name: "JilpaStoreTests",
      dependencies: ["JilpaStore", "JilpaCore", .product(name: "GRDB", package: "GRDB.swift")],
      swiftSettings: settings
    ),
    .testTarget(
      name: "JilpaCompatTests", dependencies: ["JilpaCompat", "JilpaCore"], swiftSettings: settings),
    .testTarget(name: "JilpaAXTests", dependencies: ["JilpaAX"], swiftSettings: settings),
    // The save recorder is the one part of Jilpa that watches a file system, so its tests run
    // against a real one, in a temporary folder of their own.
    .testTarget(
      name: "JilpaSensorsTests", dependencies: ["JilpaSensors", "JilpaCore"],
      swiftSettings: settings),
    .testTarget(
      name: "JilpaDialogTests",
      dependencies: ["JilpaDialog", "JilpaAX", "JilpaCompat", "JilpaCore"],
      swiftSettings: settings
    ),
    // The Navigator is the one part that sends input, so its tests take a key sender that
    // records and an AX source that answers from a script: no test can reach a real app.
    .testTarget(
      name: "JilpaNavigatorTests",
      dependencies: ["JilpaNavigator", "JilpaCore", "JilpaAX", "JilpaCompat", "JilpaDialog"],
      swiftSettings: settings
    ),
    // The strip is a window in front of another app's dialog, so what a test pins here is that
    // it can never take key status or activation from that app (contract 2).
    .testTarget(
      name: "JilpaUITests",
      dependencies: ["JilpaUI", "JilpaCore"],
      swiftSettings: settings
    ),
    .testTarget(
      name: "JilpaAppTests",
      dependencies: [
        "JilpaApp", "JilpaCore", "JilpaAX", "JilpaCompat", "JilpaDialog", "JilpaNavigator",
        "JilpaSensors", "JilpaStore",
      ],
      swiftSettings: settings
    ),
    // The counter's numbers feed a go or no-go decision, so its pure rules are tested even
    // though the tool itself is thrown away.
    .testTarget(name: "S0LoggerTests", dependencies: ["s0-logger"], swiftSettings: settings),
    // The oracle decides pass or fail for every soak and the statistics decide go or no-go.
    .testTarget(name: "JilpaSoakTests", dependencies: ["JilpaSoak"], swiftSettings: settings),
  ]
)
