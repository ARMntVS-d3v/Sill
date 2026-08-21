import AppKit

// Click trap for the notch area: the system doesn't hand clicks on the notch to us,
// so we hang our own transparent, non-activating window above the menu bar. Nothing ticks.
final class NotchClickView: NSView {
    var onClick: (() -> Void)?
    /// A file is hovering over the notch, or has left it — the capsule is told to expand/retract
    var onFilesHover: ((Bool) -> Void)?
    /// Files dropped directly on the notch — put them on the shelf without opening anything
    var onFilesDrop: (([URL]) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // MARK: - files

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        // The capsule expands immediately and stays open while the file hovers over
        // the notch. The panel doesn't open at all: the person is dragging a file,
        // not looking for a tile
        onFilesHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onFilesHover?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onFilesHover?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onFilesDrop?(urls(from: sender)) ?? false
    }

    private func hasFiles(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func urls(from sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)
        return (objects as? [URL] ?? []).filter(\.isFileURL)
    }
}

// AppKit refuses to let ordinary windows into the menu bar area — constrainFrameRect
// silently pushes the frame down. Disable that constraint for the notch window.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class NotchTrigger {
    private var windows: [NSPanel] = []
    private let onClick: (NSScreen) -> Void
    private let onFilesHover: (Bool) -> Void
    private let onFilesDrop: ([URL]) -> Bool
    private var observer: NSObjectProtocol?

    init(
        onClick: @escaping (NSScreen) -> Void,
        onFilesHover: @escaping (Bool) -> Void = { _ in },
        onFilesDrop: @escaping ([URL]) -> Bool = { _ in false }
    ) {
        self.onClick = onClick
        self.onFilesHover = onFilesHover
        self.onFilesDrop = onFilesDrop
        rebuild()
        // Monitors get connected/disconnected — rebuild the traps
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Corner radius of the notch's bottom corners. The system doesn't report it —
    /// eyeballed against the physical notch on a MacBook Pro
    static let notchCornerRadius: CGFloat = 10

    // Notch area: between auxiliaryTopLeftArea and auxiliaryTopRightArea, height safeAreaInsets.top
    static func notchRect(of screen: NSScreen) -> NSRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        return NSRect(
            x: left.maxX,
            y: screen.frame.maxY - inset,
            width: right.minX - left.maxX,
            height: inset)
    }

    private func rebuild() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        for screen in NSScreen.screens {
            guard let rect = Self.notchRect(of: screen) else { continue }
            let w = NotchPanel(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            w.isFloatingPanel = true  // before level: isFloatingPanel resets it to .floating
            // Above the panel (popUpMenu): clicking the notch closes an open panel,
            // even though the panel now covers the notch area itself
            w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NotchClickView(frame: NSRect(origin: .zero, size: rect.size))
            // A fully transparent window lets clicks pass straight through in macOS —
            // needs an opaque layer. The area is the physical notch, there are no
            // pixels there, so black isn't visible.
            //
            // But the notch's own bottom corners are rounded, and a plain rectangle
            // painted them black too — making the notch look square. Round the trap's
            // bottom corners: in those corners the screen is real, and painting over it isn't allowed
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            view.layer?.cornerRadius = Self.notchCornerRadius
            // The layer's origin is at the bottom, so the "bottom" corners are MinY
            view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            view.onClick = { [weak self] in self?.onClick(screen) }
            view.onFilesHover = { [weak self] inside in self?.onFilesHover(inside) }
            view.onFilesDrop = { [weak self] urls in self?.onFilesDrop(urls) ?? false }
            w.contentView = view
            w.setFrame(rect, display: true)  // after contentView: constrainFrameRect is already disabled
            w.orderFrontRegardless()
            windows.append(w)
            sillLog("[notch] trap \(rect), final frame \(w.frame), level \(w.level.rawValue)")
        }
        if windows.isEmpty { sillLog("[notch] no screen has a notch") }
    }
}
