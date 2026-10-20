import AppKit
import SwiftUI

@main struct NativePinCheck {
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  var presented = true
  var confirmed = false
  let parent = V3ToolPopoverAnchor(isPresented: Binding(get: { presented }, set: { presented = $0 }), onAnchorPress: { confirmed = true }, content: AnyView(Text("Tool panel")))
  let coordinator = V3ToolPopoverAnchor.Coordinator(parent: parent)
  let window = NSWindow(contentRect: NSRect(x:0,y:0,width:400,height:240), styleMask:.borderless, backing:.buffered, defer:false)
  let anchor = V3ToolAnchorView(frame:NSRect(x:280,y:180,width:36,height:36))
  var attachmentNotified = false
  anchor.onWindowAttachment = { attachmentNotified = true }
  window.contentView!.addSubview(anchor)
  precondition(attachmentNotified, "anchor should notify its host after joining the owner window")
  anchor.onWindowAttachment = nil
  coordinator.anchor = anchor
  precondition(coordinator.popover.behavior == .applicationDefined)
  precondition(anchor.hitTest(NSPoint(x:10,y:10)) == nil, "anchor must not swallow button clicks")
  let click = NSEvent.mouseEvent(with:.leftMouseDown, location:NSPoint(x:296,y:196), modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
  precondition(coordinator.handle(click) === click && presented && !confirmed, "owner-window anchor click should pass through for exactly one button action")
  precondition(coordinator.handle(click) === click && presented && !confirmed, "repeat owner-window click should pass through without a second monitor action")
  let outside = NSEvent.mouseEvent(with:.leftMouseDown, location:NSPoint(x:10,y:10),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:1)!
  precondition(coordinator.handle(outside) === outside && !presented, "outside click must close and propagate")
  presented = true
  let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{1B}",charactersIgnoringModifiers:"\u{1B}",isARepeat:false,keyCode:53)!
  precondition(coordinator.handle(escape) == nil && !presented, "Escape must close and be consumed")
  precondition(!window.isVisible && !coordinator.popover.isShown)
  print("PASS anchor attachment notification, owner-click pass-through, outside click and Escape dismissal. No windows displayed, no events sent.")
 }
}
