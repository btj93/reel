import Core
import Engine
import Foundation

let group = DisplayGroup(id: 1, displays: [1], frame: CGRect(x: -1920, y: 30, width: 1920, height: 1080))
let local = StripRect(CGRect(x: 100, y: 20, width: 300, height: 400))
let global = axRect(viewportRect(local, offset: 50), on: group)
precondition(global.rect.minX == -1870)
precondition(stripRect(global, on: group, offset: 50) == local)
print("Engine coordinate round trip: passed")
