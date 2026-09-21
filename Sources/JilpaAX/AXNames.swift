/// An attribute name. Open-ended, because host apps define their own.
public struct AXAttribute: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }
  public var description: String { rawValue }

  public static let role: AXAttribute = "AXRole"
  public static let subrole: AXAttribute = "AXSubrole"
  public static let roleDescription: AXAttribute = "AXRoleDescription"
  public static let identifier: AXAttribute = "AXIdentifier"
  public static let title: AXAttribute = "AXTitle"
  public static let label: AXAttribute = "AXDescription"
  public static let help: AXAttribute = "AXHelp"
  public static let value: AXAttribute = "AXValue"
  public static let placeholder: AXAttribute = "AXPlaceholderValue"
  public static let enabled: AXAttribute = "AXEnabled"
  public static let focused: AXAttribute = "AXFocused"

  public static let parent: AXAttribute = "AXParent"
  public static let children: AXAttribute = "AXChildren"
  public static let window: AXAttribute = "AXWindow"
  public static let topLevelElement: AXAttribute = "AXTopLevelUIElement"

  public static let position: AXAttribute = "AXPosition"
  public static let size: AXAttribute = "AXSize"
  public static let frame: AXAttribute = "AXFrame"

  public static let windows: AXAttribute = "AXWindows"
  public static let mainWindow: AXAttribute = "AXMainWindow"
  public static let focusedWindow: AXAttribute = "AXFocusedWindow"
  public static let focusedElement: AXAttribute = "AXFocusedUIElement"
  public static let frontmost: AXAttribute = "AXFrontmost"

  public static let main: AXAttribute = "AXMain"
  public static let modal: AXAttribute = "AXModal"
  public static let defaultButton: AXAttribute = "AXDefaultButton"
  public static let cancelButton: AXAttribute = "AXCancelButton"
  public static let document: AXAttribute = "AXDocument"
  public static let url: AXAttribute = "AXURL"
  public static let filename: AXAttribute = "AXFilename"

  public static let selectedChildren: AXAttribute = "AXSelectedChildren"
  public static let selectedRows: AXAttribute = "AXSelectedRows"
  public static let selectedTextRange: AXAttribute = "AXSelectedTextRange"
  public static let rows: AXAttribute = "AXRows"
  public static let visibleRows: AXAttribute = "AXVisibleRows"
  /// The columns of a browser in column view, each a scroll area around a list.
  public static let columns: AXAttribute = "AXColumns"
}

public struct AXAction: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }
  public var description: String { rawValue }

  public static let press: AXAction = "AXPress"
  public static let confirm: AXAction = "AXConfirm"
  public static let cancel: AXAction = "AXCancel"
  public static let showMenu: AXAction = "AXShowMenu"
  public static let raise: AXAction = "AXRaise"
}

public struct AXNotification: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }
  public var description: String { rawValue }

  // Subscribed on the application element for every observed app.
  public static let windowCreated: AXNotification = "AXWindowCreated"
  public static let sheetCreated: AXNotification = "AXSheetCreated"
  public static let focusedWindowChanged: AXNotification = "AXFocusedWindowChanged"
  public static let focusedElementChanged: AXNotification = "AXFocusedUIElementChanged"

  // Added on a dialog element once it is recognized.
  public static let elementDestroyed: AXNotification = "AXUIElementDestroyed"
  public static let moved: AXNotification = "AXMoved"
  public static let resized: AXNotification = "AXResized"

  public static let valueChanged: AXNotification = "AXValueChanged"
  public static let titleChanged: AXNotification = "AXTitleChanged"
  public static let selectedChildrenChanged: AXNotification = "AXSelectedChildrenChanged"
  public static let selectedRowsChanged: AXNotification = "AXSelectedRowsChanged"
  public static let mainWindowChanged: AXNotification = "AXMainWindowChanged"
  public static let applicationActivated: AXNotification = "AXApplicationActivated"
  public static let applicationDeactivated: AXNotification = "AXApplicationDeactivated"
  public static let created: AXNotification = "AXCreated"
}
