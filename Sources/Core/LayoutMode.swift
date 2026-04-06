import CoreGraphics

public enum LayoutMode: Sendable {
    case normal
    case minimap(draggedColumnIndex: Int, insertionIndex: Int, cursorPosition: CGPoint)
}
