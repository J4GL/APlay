// impl: WIN-001 rule 12 — no storyboard, no nib, no main menu bar item for
// zoom. The app is assembled in code so the window can be borderless from the
// first frame rather than inheriting a titled window from a nib.

import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
