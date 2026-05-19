import Foundation

/// Abstract contracts for the recording-linked visual managers. Conformers are
/// platform-specific (engine-domain contracts; see windows-port-inventory §7).

protocol OverlayManaging: AnyObject {
  var overlayEnabledByUser: Bool { get set }
  var overlayLinkedToRecording: Bool { get set }
  var preferredOverlaySize: Double { get set }
  func showIfNeeded(isRecording: Bool)
  func hide()
}

protocol CursorHighlighting: AnyObject {
  var enabledByUser: Bool { get set }
  var linkedToRecording: Bool { get set }
  func update(isRecording: Bool)
}

protocol RecordingIndicatorManaging: AnyObject {
  var enabledByUser: Bool { get set }
  var pinned: Bool { get set }
  func update(isRecording: Bool)
}
