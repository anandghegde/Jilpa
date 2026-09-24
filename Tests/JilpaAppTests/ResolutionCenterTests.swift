import Foundation
import JilpaAX
import JilpaCompat
import JilpaConfig
import JilpaCore
import Testing

@testable import JilpaApp
@testable import JilpaDialog

private let hostPid: pid_t = 4_830_000
private let servicePid: pid_t = 4_830_077
private func element(_ number: pid_t) -> AXElement { .application(pid: 4_830_100 + number) }

private let anchors = DialogAnchors(
  confirm: element(1), cancel: element(2), pathPopup: element(3), nameField: element(4),
  disclosure: nil, browser: element(5), view: .column, foreignPids: [servicePid])

private func cell(_ app: AppID, _ variant: DialogVariant) -> CompatCell {
  CompatCell(
    app: app, os: [OSMatch("26")!], variant: variant, support: .supported,
    signature: variant.panel == .save ? .standardSavePanel : .standardOpenPanel,
    strategy: .goToFolder26)
}

/// One dialog as the coordinator hands it over: read once, with a folder in it and nothing done
/// to it by the user unless the test says otherwise.
private func observed(
  app: AppID? = "com.example.host", variant: DialogVariant = .saveSheet,
  purpose: Resolved<DialogPurpose>? = nil, filename: String? = "Report.txt",
  latched: UserActivity? = nil, state: PrivacyState = PrivacyState()
) -> ObservedDialog {
  let process = AppProcess(pid: hostPid, app: app, version: "1.0", isRegular: true)
  var descriptor = DialogDescriptor(
    variant: variant, matched: variant.panel == .save ? .standardSavePanel : .standardOpenPanel,
    anchors: anchors, keyTarget: servicePid,
    answer: .cell(cell(app ?? "com.example.host", variant)))!
  // The panel is the evidence, so a real descriptor always knows its purpose. This is the one
  // reading a descriptor cannot give and the resolver still has a rule for.
  if let purpose { descriptor.purpose = purpose }
  var session = DialogSession(
    id: DialogSession.ID(pid: hostPid, serial: 1), window: element(0), descriptor: descriptor,
    trigger: .notification(.sheetCreated), sameFolder: { $0.path == $1.path })
  session.handle(
    .snapshot(
      DialogSnapshot(
        anchors: anchors, folder: .known(URL(fileURLWithPath: "/tmp"), source: .columnSelection),
        filename: filename, selection: .known(.none, source: .listingSelection))))
  if let latched { session.handle(.activity(latched)) }
  return ObservedDialog(
    app: process,
    policy: PrivacyGate().sessionPolicy(GateContext(state: state, app: process.app)),
    session: session)
}

/// A file system that answers for the folders a test names and for nothing else. `stat` is the
/// resolver's only question about a destination, so this is the whole of the edge.
private func edge(present: [String]) -> LocationEdge {
  let volume = "0A0B0C0D-0000-0000-0000-000000000001"
  var table: [String: LocationAnswer] = [:]
  for (offset, path) in present.enumerated() {
    table[path] = .found(
      LocationSighting(
        path: path,
        identity: LocationIdentity(
          volumeUUID: volume, fileID: UInt64(100 + offset), persistentIDs: true)))
  }
  let answers = table
  return LocationEdge(look: { answers[$0.path] ?? .notFound })
}

private let home = "/Users/someone"
private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 UTC

private func template(_ source: String) -> Template {
  do { return try Template(source) } catch { fatalError("bad test template \(source): \(error)") }
}

@MainActor
private func center(
  defaults: [ExplicitDefault] = [], pin: PinEntry? = nil, contexts: [ContextEntry] = [],
  present: [String] = ["\(home)/Desktop", "\(home)/Reports", "\(home)/Clients/Acme"]
) -> ResolutionCenter {
  var model = ConfigModel()
  model.defaults = defaults.map { Sourced($0, .handOwned) }
  model.contexts = contexts.map { Sourced($0, .handOwned) }
  model.pin = pin
  let center = ResolutionCenter(
    home: home, places: edge(present: present), now: { now },
    timeZone: { TimeZone(identifier: "UTC") ?? .gmt })
  center.configChanged(model)
  // The pin reaches the centre from the pin centre, which reads it out of the same model.
  center.pinChanged(model.resolverPin(home: home))
  return center
}

/// The one live caller of `Resolver.resolve` (D8). What the resolver does with an input is its
/// own tests' business; what these check is that a dialog and a configuration file become the
/// right input, and that availability is a real `stat` of the folder that is about to win.
@MainActor
@Suite("Resolution centre")
struct ResolutionCenterTests {
  static let host: AppID = "com.example.host"
  static let other: AppID = "com.example.other"

  /// The acceptance row: an explicit default for app and purpose names where the dialog goes.
  @Test func aDefaultForThisAppAndPurposeNamesTheDestination() async {
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.host, purpose: .only(.save), destination: template("~/Reports"))
    ]).resolution(for: observed())
    #expect(
      resolution?.outcome
        == .navigate(
          ResolvedDestination(path: "\(home)/Reports", trigger: .explicitDefault(forPurpose: true))))
  }

  /// The other half of it: an unknown purpose uses only the purpose-neutral default. The
  /// purpose-specific one is not a guess to fall back on — consent is per app and purpose, and a
  /// dialog whose purpose is not evidence has no purpose to have consented for.
  @Test func anUnknownPurposeUsesOnlyThePurposeNeutralDefault() async {
    let both = [
      ExplicitDefault(app: Self.host, purpose: .only(.save), destination: template("~/Reports")),
      ExplicitDefault(app: Self.host, destination: template("~/Desktop")),
    ]
    let dialog = observed(purpose: .unknown("panel-unreadable"))
    let resolution = await center(defaults: both).resolution(for: dialog)
    #expect(
      resolution?.outcome
        == .navigate(
          ResolvedDestination(path: "\(home)/Desktop", trigger: .explicitDefault(forPurpose: false))))
    #expect(resolution?.defaults.first?.verdict == .purposeUnknown)
  }

  /// A default belongs to the app it names. Nothing here matches by anything else, so a dialog
  /// of another app resolves to nothing at all and keeps its own folder.
  @Test func anotherAppsDefaultIsNotThisAppsDefault() async {
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.other, destination: template("~/Desktop"))
    ]).resolution(for: observed())
    #expect(resolution?.outcome == .keepNative(.nothingMatched))
    #expect(resolution?.defaults.isEmpty == true)
  }

  /// An app with no bundle identifier. There is nothing to match a default against and nothing
  /// for the gate to check an exclusion against either, so there is no resolution to be had.
  @Test func anAppThatCannotBeNamedResolvesNothing() async {
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.host, destination: template("~/Desktop"))
    ]).resolution(for: observed(app: nil))
    #expect(resolution == nil)
  }

  /// Contract 4's first step, kept true of this call as well: whatever the user did in the
  /// dialog beats every automation, and the resolution says so rather than naming a folder that
  /// something else would then have to refuse.
  @Test func aDialogTheUserHasTouchedYieldsToThem() async {
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.host, destination: template("~/Desktop"))
    ]).resolution(for: observed(latched: .filename))
    #expect(resolution?.outcome == .yieldToUser)
  }

  /// Contract 5, end to end: the winner is checked against the file system and a folder that is
  /// not there is refused. Not replaced — the purpose-neutral default that is there does not get
  /// the dialog, and evaluation stops at the one that lost.
  @Test func aDefaultThatIsNotThereIsRefusedAndNothingTakesItsPlace() async {
    let resolution = await center(
      defaults: [
        ExplicitDefault(app: Self.host, purpose: .only(.save), destination: template("~/Archive")),
        ExplicitDefault(app: Self.host, destination: template("~/Desktop")),
      ]
    ).resolution(for: observed())
    #expect(
      resolution?.outcome
        == .refuse(
          ResolvedDestination(path: "\(home)/Archive", trigger: .explicitDefault(forPurpose: true)),
          .unavailable(.missing)))
  }

  /// A destination whose path leads to a file rather than a folder is the same kind of refusal,
  /// and it is the one that proves the availability answer is a real `stat` of the named path
  /// and not a check that some row exists.
  @Test func aDestinationThatIsNotAFolderIsRefused() async {
    let file = LocationSighting(
      path: "\(home)/Reports",
      identity: LocationIdentity(volumeUUID: "V", fileID: 7, persistentIDs: true), isFolder: false)
    let places = LocationEdge(look: { $0.path == "\(home)/Reports" ? .found(file) : .notFound })
    var model = ConfigModel()
    model.defaults = [
      Sourced(ExplicitDefault(app: Self.host, destination: template("~/Reports")), .handOwned)
    ]
    let center = ResolutionCenter(
      home: home, places: places, now: { now }, timeZone: { .gmt })
    center.configChanged(model)
    let resolution = await center.resolution(for: observed())
    #expect(
      resolution?.outcome
        == .refuse(
          ResolvedDestination(path: "\(home)/Reports", trigger: .explicitDefault(forPurpose: false)),
          .unavailable(.notAFolder)))
  }

  /// Contract 7: in private mode the gate refuses the automatic navigation and the folder is a
  /// suggestion instead. It is still the folder the user configured, so it is offered rather
  /// than dropped — passing a gate is not consent, and failing one is not a reason to forget.
  @Test func privateModeOffersTheDefaultWithoutGoingThere() async {
    let dialog = observed(state: PrivacyState(privateMode: true))
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.host, destination: template("~/Desktop"))
    ]).resolution(for: dialog)
    #expect(
      resolution?.outcome
        == .suggestOnly(
          ResolvedDestination(path: "\(home)/Desktop", trigger: .explicitDefault(forPurpose: false)),
          .privateMode))
  }

  /// An excluded app gets nothing at all, not even a suggestion. The gate is asked once and its
  /// answer covers both, which is what one gate before every automation read means.
  @Test func anExcludedAppGetsNothing() async {
    var state = PrivacyState()
    state.exclusions.apps = [Self.host]
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.host, destination: template("~/Desktop"))
    ]).resolution(for: observed(state: state))
    #expect(resolution?.outcome == .keepNative(.gateDenied(.appExcluded)))
  }

  /// `{context}` in a default expands under the pin, which is the only thing that names the
  /// active context until sensing lands. The pin comes out of the same configuration load the
  /// defaults do, and the centre is what puts the two together.
  @Test func aContextVariableExpandsUnderThePin() async {
    let resolution = await center(
      defaults: [ExplicitDefault(app: Self.host, destination: template("~/Clients/{context}"))],
      pin: PinEntry(target: .context("acme")),
      contexts: [ContextEntry(id: "acme", name: "Acme")]
    ).resolution(for: observed())
    #expect(resolution?.context == .context(ContextRef(id: "acme", name: "Acme"), .pin))
    #expect(
      resolution?.outcome
        == .navigate(
          ResolvedDestination(
            path: "\(home)/Clients/Acme", trigger: .explicitDefault(forPurpose: false))))
  }

  /// Without a pin the same default matches nothing: a variable with no value is a failed match,
  /// not an empty path component. Contract 5 again, one step earlier.
  @Test func theSameDefaultMatchesNothingWithNoContext() async {
    let resolution = await center(defaults: [
      ExplicitDefault(app: Self.host, destination: template("~/Clients/{context}"))
    ]).resolution(for: observed())
    #expect(resolution?.outcome == .keepNative(.nothingMatched))
    #expect(resolution?.defaults.first?.verdict == .missingVariable([.context]))
  }

  /// An open dialog and a save dialog of the same app are two purposes, and a default for one is
  /// not a default for the other. The purpose comes from the panel, which is the only evidence
  /// there is for it.
  @Test func anOpenDialogDoesNotTakeTheSaveDefault() async {
    let defaults = [
      ExplicitDefault(app: Self.host, purpose: .only(.save), destination: template("~/Reports")),
      ExplicitDefault(app: Self.host, purpose: .only(.open), destination: template("~/Desktop")),
    ]
    let resolution = await center(defaults: defaults).resolution(
      for: observed(variant: .openWindow, filename: nil))
    #expect(
      resolution?.outcome
        == .navigate(
          ResolvedDestination(path: "\(home)/Desktop", trigger: .explicitDefault(forPurpose: true))))
  }

  /// Configuration is read on every load and nothing else. A default that was there and is not
  /// any more stops naming a destination on the next dialog.
  @Test func aDefaultThatWasRemovedStopsNamingAnything() async {
    let center = center(defaults: [
      ExplicitDefault(app: Self.host, destination: template("~/Desktop"))
    ])
    center.configChanged(ConfigModel())
    let resolution = await center.resolution(for: observed())
    #expect(resolution?.outcome == .keepNative(.nothingMatched))
  }
}
