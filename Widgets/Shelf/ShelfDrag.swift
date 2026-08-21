import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Handing a file off the shelf goes through NSFilePromiseProvider: the receiving
// app says where to put the file and gets it at the moment it's actually ready
// to accept it. That's how Finder and nearly everything else with drag-and-drop
// works.
//
// The shelf holds references, so "fulfilling the promise" means copying the
// original to the named location. The original stays put: dragging off the
// shelf never moves or deletes anything.
struct FileDragHandle: NSViewRepresentable {
    let url: URL?
    /// Icon that follows the cursor
    let icon: NSImage?
    /// Double-click opens the file: this layer sits on top of the row and
    /// swallows clicks, so it has to hand that action back
    var onOpen: () -> Void = {}

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.url = url
        view.icon = icon
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.url = url
        view.icon = icon
        view.onOpen = onOpen
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var icon: NSImage?
    var onOpen: () -> Void = {}
    /// The provider holds the delegate weakly — otherwise it dies mid-drag
    private var promise: ShelfPromiseDelegate?

    override var isFlipped: Bool { true }
    /// This view is only a gesture source; everything else is drawn by SwiftUI beneath it
    override func hitTest(_ point: NSPoint) -> NSView? {
        url == nil ? nil : super.hitTest(point)
    }

    // A single click is swallowed silently by this layer (it's the start of a
    // possible drag); a double click opens the file. Right-click is passed on
    // down the chain to the SwiftUI menu
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onOpen() }
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        nextResponder?.rightMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.data.identifier
        let delegate = ShelfPromiseDelegate(url: url)
        promise = delegate
        let provider = NSFilePromiseProvider(fileType: type, delegate: delegate)

        let item = NSDraggingItem(pasteboardWriter: provider)
        let image = icon ?? NSWorkspace.shared.icon(forFile: url.path)
        // The icon follows from where it was picked up, not the corner of the screen
        let size = NSSize(width: 48, height: 48)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        item.setDraggingFrame(NSRect(origin: origin, size: size), contents: image)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Copy, not move: the file on disk must not be touched, the shelf only holds a reference
        .copy
    }
}

/// The promise delegate. A separate class rather than the view itself: its methods
/// arrive on their own queue, and a @MainActor object would need each one
/// de-isolated individually
final class ShelfPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let url: URL
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(url: URL) {
        self.url = url
        super.init()
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, fileNameForType type: String
    ) -> String {
        url.lastPathComponent
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo destination: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        do {
            // The receiver already created an empty file at this location — replace it
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
}
