import Foundation
import JilpaCompat
import JilpaCore
import JilpaDialog

/// The app's answer to "is this a dialog this build can drive": the compatibility bundle in
/// force, asked for the running OS (contract: data narrows, code broadens).
///
/// Two things are the owner's and neither can be invented here. The production Ed25519 public
/// key that `trustedKeys` carries is made with `compat-sign keygen` and its private half never
/// enters this repository. The signed bundle it vouches for is an app resource, built by the
/// same tool. Until both exist, `active` is nil, every answer is `.unlisted`, and every dialog
/// gets the behavior it would have without Jilpa: no strip, no keys, nothing sent. That is the
/// fail-to-stock rule, not a placeholder.
public struct CompatSource: Sendable {
  /// The raw 32-byte Ed25519 public keys this build trusts. More than one only while a key is
  /// being rotated.
  public static let trustedKeys: [Data] = []
  /// The signed bundle in the app's resources, by name and extension.
  public static let bundledResource = (name: "compat", extension: "json")

  public let store: CompatStore
  private let os: OSRelease

  public init(store: CompatStore, os: OSRelease = OSRelease(ProcessInfo().operatingSystemVersion))
  {
    self.store = store
    self.os = os
  }

  /// Reads the app's resources and the support directory, which blocks. Called once at launch.
  public static func live(
    bundle: Bundle = .main, support: URL = CompatSource.supportDirectory
  ) -> CompatSource {
    CompatSource(
      store: CompatStore(
        directory: support.appendingPathComponent("compat", isDirectory: true),
        verifier: BundleVerifier(trustedKeys: trustedKeys),
        bundled: bundled(in: bundle)))
  }

  public static var supportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    let root = base.first ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent(Subsystem.name, isDirectory: true)
  }

  /// Unverified on purpose: `CompatStore` puts it through the same verifier as anything that
  /// arrives over the network, so being shipped inside the app vouches for nothing by itself.
  static func bundled(in bundle: Bundle) -> SignedBundle? {
    guard
      let url = bundle.url(
        forResource: bundledResource.name, withExtension: bundledResource.extension),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(SignedBundle.self, from: data)
  }

  /// What `DialogCoordinator.Services.live` asks of it. An app with no identity is unlisted:
  /// a cell names an app, and nothing else may stand in for one.
  public func answer(_ process: AppProcess, _ variant: DialogVariant) -> CompatAnswer {
    guard let bundle = store.active?.bundle, let app = process.app else { return .unlisted }
    return bundle.answer(app: app, appVersion: process.version, os: os, variant: variant)
  }
}
