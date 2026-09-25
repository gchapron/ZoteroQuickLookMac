#!/usr/bin/env swift

// Read-only native PDF preview. Zotero exports its annotations into a temporary
// PDF before invoking this helper; the helper never writes a PDF to disk.
// Usage: pdfpreview /absolute/document.pdf [/absolute/another.pdf ...]
//        pdfpreview --self-test

import AppKit
import CoreText
import PDFKit

private let previewName = "ZoteroQuickLookMac"
// Adjacent pages contribute both a bottom and a top margin, so each is
// half the side margin to keep the combined gap the same width.
private let previewPageMargins = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

private func reportError(_ message: String) {
    fputs("\(previewName): \(message)\n", stderr)
}

private func hasSubtype(_ annotation: PDFAnnotation, _ subtype: PDFAnnotationSubtype) -> Bool {
    // PDFAnnotation.type omits the slash present in PDFAnnotationSubtype's
    // PDF-name raw value (for example, "Highlight" versus "/Highlight").
    annotation.type == subtype.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

private func prepareReadOnlyAnnotations(in document: PDFDocument) {
    for pageIndex in 0..<document.pageCount {
        guard let page = document.page(at: pageIndex) else { continue }
        for annotation in page.annotations {
            // PDF annotation ReadOnly, Locked and LockedContents flags. Keep
            // existing visibility/print flags and appearance streams intact.
            let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
            annotation.setValue(NSNumber(value: flags | (1 << 6) | (1 << 7) | (1 << 9)),
                                forAnnotationKey: .flags)
            if hasSubtype(annotation, .widget) {
                let fieldFlags = (annotation.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
                annotation.setValue(NSNumber(value: fieldFlags | 1), forAnnotationKey: .widgetFieldFlags)
            }
        }
    }
}

private final class PreviewPDFView: PDFView, NSMenuItemValidation {
    // Injection lets the self-test exercise the real Copy action without
    // changing the user's general pasteboard.
    var copyPasteboard = NSPasteboard.general

    var canCopySelection: Bool {
        document?.allowsCopying == true && !(currentSelection?.string?.isEmpty ?? true)
    }

    override func copy(_ sender: Any?) {
        guard canCopySelection, let text = currentSelection?.string else { return }
        copyPasteboard.clearContents()
        copyPasteboard.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // The default PDFKit menu can offer actions such as editing a note.
        // A preview exposes only selection/copy and navigation/zoom elsewhere.
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        let selectItem = menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectItem.target = self
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return canCopySelection }
        return document != nil
    }
}

private struct PreviewLayout {
    let contentSize: NSSize
    let scale: CGFloat

    init(page: PDFPage?, visibleFrame: NSRect) {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
        let availableWidth = max(1, visibleFrame.width - 48)
        let availableHeight = max(1, visibleFrame.height - 48 - titlebarHeight)
        let rawBounds = page?.bounds(for: .cropBox) ?? NSRect(x: 0, y: 0, width: 612, height: 792)
        // Crop boxes are in unrotated page coordinates, including nonzero origins.
        let pageSize = rawBounds.applying(page?.transform(for: .cropBox) ?? .identity).size
        let pageWidth = max(1, pageSize.width)
        let pageHeight = max(1, pageSize.height)
        // Include page-break margins and room for a non-overlay vertical scroller.
        let horizontalPadding = previewPageMargins.left + previewPageMargins.right
            + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let verticalPadding = previewPageMargins.top + previewPageMargins.bottom
        let widthScale = max(1, min(900, availableWidth) - horizontalPadding) / pageWidth
        let heightScale = max(1, availableHeight - verticalPadding) / pageHeight
        // Fit ordinary paper in full. Long screenshots keep a readable width and scroll.
        scale = pageHeight / pageWidth > 2 ? widthScale : min(widthScale, heightScale)
        contentSize = NSSize(
            width: min(availableWidth, max(360, ceil(pageWidth * scale + horizontalPadding))),
            height: min(availableHeight, max(300, ceil(pageHeight * scale + verticalPadding)))
        )
    }
}

private final class PreviewWindow: NSWindow {
    let pdfView: PreviewPDFView
    private let initialScale: CGFloat
    private let initialVisibleFrame: NSRect

    init(document: PDFDocument, url: URL, visibleFrame: NSRect? = nil) {
        let visibleFrame = visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let layout = PreviewLayout(page: document.page(at: 0), visibleFrame: visibleFrame)
        initialScale = layout.scale
        initialVisibleFrame = visibleFrame
        pdfView = PreviewPDFView(frame: NSRect(origin: .zero, size: layout.contentSize))
        super.init(contentRect: pdfView.frame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = url.deletingPathExtension().lastPathComponent
        contentMinSize = NSSize(width: min(360, layout.contentSize.width),
                                height: min(300, layout.contentSize.height))
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = false
        tabbingMode = .disallowed
        contentView = pdfView
        pdfView.autoresizingMask = [.width, .height]
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = previewPageMargins
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.acceptsDraggedFiles = false
        if #available(macOS 13.0, *) { pdfView.isInMarkupMode = false }
        prepareReadOnlyAnnotations(in: document)
        // autoScales uses fit-width in continuous mode, which clips portrait pages.
        pdfView.autoScales = false
        pdfView.document = document
        setFrameOrigin(NSPoint(x: visibleFrame.midX - frame.width / 2,
                               y: visibleFrame.midY - frame.height / 2))
        positionFirstPage()
    }

    func positionFirstPage() {
        guard let page = pdfView.document?.page(at: 0) else { return }
        pdfView.layoutSubtreeIfNeeded()
        // Assigning a document resets PDFKit's scale limits. Set them afterward
        // so unusually large page sizes can still fit below the default 10% zoom.
        pdfView.minScaleFactor = min(0.1, initialScale)
        pdfView.maxScaleFactor = max(10, initialScale)
        pdfView.scaleFactor = initialScale
        pdfView.layoutDocumentView()
        let transform = page.transform(for: pdfView.displayBox)
        let bounds = page.bounds(for: pdfView.displayBox).applying(transform)
        // PDF destinations use page space. Convert the displayed top-left back
        // so rotated pages and cropped PDFs open at the same visual position.
        let topLeft = CGPoint(x: bounds.minX,
                              y: bounds.maxY + pdfView.pageBreakMargins.top / initialScale)
            .applying(transform.inverted())
        pdfView.go(to: PDFDestination(page: page, at: topLeft))
    }

    func constrainToVisibleScreen() {
        var constrained = frame
        constrained.origin.x = min(max(frame.minX, initialVisibleFrame.minX),
                                   initialVisibleFrame.maxX - frame.width)
        constrained.origin.y = min(max(frame.minY, initialVisibleFrame.minY),
                                   initialVisibleFrame.maxY - frame.height)
        setFrame(constrained, display: false)
    }
}

private func isDismissalEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers.isEmpty && (event.keyCode == 53 || event.keyCode == 49) { return true }
    return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "y"
}

private final class PreviewApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private(set) var windows: [PreviewWindow] = []
    private var keyMonitor: Any?
    private let documents: [(URL, PDFDocument)]

    init(documents: [(URL, PDFDocument)]) {
        self.documents = documents
    }

    var activeView: PreviewPDFView? {
        (NSApp.keyWindow as? PreviewWindow)?.pdfView
            ?? (NSApp.mainWindow as? PreviewWindow)?.pdfView
            ?? windows.last?.pdfView
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createWindows(show: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isDismissalEvent(event) else { return event }
            self?.closePreviews(nil)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = windows.last {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.pdfView)
        }
    }

    func createWindows(show: Bool) {
        installMenu()
        var cascadePoint: NSPoint?
        for (url, document) in documents {
            let window = PreviewWindow(document: document, url: url)
            window.delegate = self
            if let point = cascadePoint { window.setFrameTopLeftPoint(point) }
            window.constrainToVisibleScreen()
            cascadePoint = NSPoint(x: window.frame.minX + 24, y: window.frame.maxY - 24)
            windows.append(window)
            if show {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(window.pdfView)
                // The scroll view gets its final viewport after the window opens.
                // Set the destination again then, before the user starts reading.
                window.positionFirstPage()
                DispatchQueue.main.async { [weak window] in window?.positionFirstPage() }
            }
        }
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = mainMenu.addItem(withTitle: previewName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: previewName)
        appItem.submenu = appMenu
        addItem(to: appMenu, title: "Close All Previews", action: #selector(closePreviews(_:)), key: "q")

        let fileItem = mainMenu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        addItem(to: fileMenu, title: "Close Window", action: #selector(closeWindow(_:)), key: "w")
        addItem(to: fileMenu, title: "Close All Previews", action: #selector(closePreviews(_:)), key: "y")

        let editItem = mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        addItem(to: editMenu, title: "Copy", action: #selector(copySelection(_:)), key: "c")
        addItem(to: editMenu, title: "Select All", action: #selector(selectAllText(_:)), key: "a")

        let viewItem = mainMenu.addItem(withTitle: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        addItem(to: viewMenu, title: "Zoom In", action: #selector(zoomIn(_:)), key: "+")
        addItem(to: viewMenu, title: "Zoom Out", action: #selector(zoomOut(_:)), key: "-")
        NSApp.mainMenu = mainMenu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        // Target the current preview explicitly: PDFKit sometimes makes an
        // internal view first responder, which otherwise swallows Command-C.
        item.target = self
    }

    @objc func copySelection(_ sender: Any?) { activeView?.copy(sender) }
    @objc func selectAllText(_ sender: Any?) { activeView?.selectAll(sender) }
    @objc func zoomIn(_ sender: Any?) { activeView?.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { activeView?.zoomOut(sender) }

    @objc func closeWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? windows.last)?.performClose(sender)
    }

    @objc func closePreviews(_ sender: Any?) {
        for window in windows { window.close() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copySelection(_:)) { return activeView?.canCopySelection == true }
        return activeView != nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? PreviewWindow else { return }
        windows.removeAll { $0 === closedWindow }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }
}

// A small integration test for the two reasons this helper exists: actual PDF
// text selection/copy and rendered highlights. It uses no user documents and
// never orders a window front or writes to the general pasteboard.
private func runSelfTest() -> Bool {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
        if condition() { return true }
        reportError("self-test failed: \(message)")
        return false
    }

    let data = NSMutableData()
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { return false }
    context.beginPDFPage(nil)
    let text = "Selectable highlighted PDF text"
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black
    ])
    context.textPosition = CGPoint(x: 30, y: 160)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    context.endPDFPage()
    context.closePDF()
    guard let document = PDFDocument(data: data as Data),
          let page = document.page(at: 0),
          let selection = document.findString(text, withOptions: []).first else {
        reportError("self-test failed: generated PDF has no selectable text")
        return false
    }

    let highlight = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
    highlight.color = .yellow
    page.addAnnotation(highlight)
    let field = PDFAnnotation(bounds: CGRect(x: 30, y: 40, width: 100, height: 25),
                              forType: .widget, withProperties: nil)
    field.widgetFieldType = .text
    field.fieldName = "Read-only preview field"
    field.widgetStringValue = "Original value"
    page.addAnnotation(field)
    // Round trip through PDF serialization, like the annotated export from Zotero.
    guard let annotatedData = document.dataRepresentation(),
          let reopened = PDFDocument(data: annotatedData),
          let reopenedPage = reopened.page(at: 0) else { return false }

    let delegate = PreviewApplicationDelegate(documents: [
        (URL(fileURLWithPath: "/self-test-one.pdf"), reopened),
        (URL(fileURLWithPath: "/self-test-two.pdf"), reopened)
    ])
    delegate.createWindows(show: false)
    guard require(delegate.windows.count == 2, "multiple PDFs must create separate windows"),
          let view = delegate.activeView else { return false }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    guard require(!pasteboard.name.rawValue.isEmpty,
                  "private pasteboard unavailable; run outside a sandbox that blocks macOS pasteboard services") else { return false }
    view.copyPasteboard = pasteboard
    delegate.selectAllText(nil)
    guard require(view.currentSelection?.string?.contains(text) == true, "Select All must select PDF text"),
          let copyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                                          charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8),
          require(NSApp.mainMenu?.performKeyEquivalent(with: copyEvent) == true, "Command-C must resolve through the menu"),
          require(pasteboard.string(forType: .string)?.contains(text) == true, "Command-C must copy selected text") else { return false }

    view.clearSelection()
    delegate.copySelection(nil)
    guard require(pasteboard.string(forType: .string)?.contains(text) == true,
                  "Copy with no selection must preserve pasteboard contents"),
          require(reopenedPage.annotations.filter { hasSubtype($0, .widget) }.allSatisfy {
              let flags = ($0.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
              return flags & 1 == 1
          }, "form fields must be read-only in the preview") else { return false }

    guard require(reopenedPage.annotations.contains { hasSubtype($0, .highlight) && $0.shouldDisplay },
                  "highlight annotation must remain visible") else { return false }
    let thumbnail = reopenedPage.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox)
    guard let tiff = thumbnail.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return false }
    var yellowPixels = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.6 && color.greenComponent > 0.6 && color.blueComponent < 0.4 {
                yellowPixels += 1
            }
        }
    }
    guard require(yellowPixels > 100, "PDFKit must render the embedded highlight") else { return false }

    // Assert real PDFKit viewport geometry, not just the window-sizing formula.
    // In particular, PDFView's root bounds can include the titlebar area.
    let testScreens = [
        NSRect(x: 0, y: 25, width: 1280, height: 775),
        NSRect(x: 1440, y: 0, width: 1920, height: 1055),
        NSRect(x: 0, y: 0, width: 800, height: 550)
    ]
    let pageCases: [(String, CGSize, Int, CGRect?, Bool)] = [
        ("A4", CGSize(width: 595, height: 842), 0, nil, false),
        ("Letter", CGSize(width: 612, height: 792), 0, nil, false),
        ("Landscape", CGSize(width: 842, height: 595), 0, nil, false),
        ("Rotated portrait", CGSize(width: 842, height: 595), 90, nil, false),
        ("Cropped portrait", CGSize(width: 700, height: 1100), 180,
         CGRect(x: 40, y: 120, width: 595, height: 842), false),
        ("Long webpage", CGSize(width: 595, height: 3600), 0, nil, true),
        ("Rotated long webpage", CGSize(width: 3600, height: 595), 90, nil, true),
        ("Rotated long webpage 270", CGSize(width: 3600, height: 595), 270, nil, true),
        ("Large-format portrait", CGSize(width: 11900, height: 16840), 0, nil, false)
    ]
    for screen in testScreens {
        for (name, size, rotation, crop, isTall) in pageCases {
            let fixture = PDFDocument()
            for _ in 0..<2 {
                let fixturePage = PDFPage()
                fixturePage.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
                if let crop { fixturePage.setBounds(crop, for: .cropBox) }
                fixturePage.rotation = rotation
                fixture.insert(fixturePage, at: fixture.pageCount)
            }
            let window = PreviewWindow(document: fixture, url: URL(fileURLWithPath: "/layout.pdf"),
                                       visibleFrame: screen)
            // Exercise the deferred startup layout too, then check the settled viewport.
            DispatchQueue.main.async { window.positionFirstPage() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            defer { window.close() }
            let pdf = window.pdfView
            guard let page = fixture.page(at: 0),
                  let clip = pdf.documentView?.enclosingScrollView?.contentView else { return false }
            let viewport = pdf.convert(clip.bounds, from: clip).intersection(pdf.visibleRect)
            let rendered = pdf.convert(page.bounds(for: pdf.displayBox), from: page).standardized
            guard require(screen.insetBy(dx: -1, dy: -1).contains(window.frame),
                          "\(name): window must stay within the available screen"),
                  require(rendered.minX >= viewport.minX - 2 && rendered.maxX <= viewport.maxX + 2,
                          "\(name): page width must fit the viewport (page \(rendered), viewport \(viewport), scale \(pdf.scaleFactor), minimum \(pdf.minScaleFactor))") else { return false }
            if isTall {
                let pageTop = pdf.isFlipped ? rendered.minY : rendered.maxY
                let viewportTop = pdf.isFlipped ? viewport.minY : viewport.maxY
                guard require(abs(pageTop - viewportTop) <= 25,
                              "\(name): long page must open at its top"),
                      require(rendered.height > viewport.height,
                              "\(name): long page must remain readable and scroll vertically") else { return false }
            } else {
                guard require(viewport.insetBy(dx: -2, dy: -2).contains(rendered),
                              "\(name): the entire first page must be visible") else { return false }
            }
            // Initialization must not install a later callback that undoes user zoom.
            let zoomed = pdf.scaleFactor * 1.2
            pdf.scaleFactor = zoomed
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            guard require(abs(pdf.scaleFactor - zoomed) < 0.001,
                          "\(name): user zoom must survive subsequent layout") else { return false }
        }
    }

    for (keyCode, characters, modifiers, shouldDismiss) in [
        (UInt16(49), " ", NSEvent.ModifierFlags(), true),
        (UInt16(53), "\u{1b}", NSEvent.ModifierFlags(), true),
        (UInt16(16), "y", NSEvent.ModifierFlags.command, true),
        (UInt16(8), "c", NSEvent.ModifierFlags.command, false),
        (UInt16(49), " ", NSEvent.ModifierFlags.command, false)
    ] {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode),
              require(isDismissalEvent(event) == shouldDismiss, "dismissal shortcut routing (key code \(keyCode))") else { return false }
    }
    delegate.windows.first?.close()
    guard require(delegate.windows.count == 1, "closing one PDF must keep the other preview") else { return false }
    delegate.closePreviews(nil)
    guard require(delegate.windows.isEmpty, "Close All must release every preview window"),
          require(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                  "the helper must terminate after its last window closes") else { return false }

    print("PDFKit self-test passed: selectable text, Command-C/private pasteboard, read-only forms, rendered highlight, first-page fit/top alignment, capped tall pages, dismissal shortcuts, multiple-window teardown.")
    return true
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--self-test"] {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    exit(runSelfTest() ? 0 : 1)
}
guard !arguments.isEmpty else {
    reportError("Usage: pdfpreview /absolute/document.pdf [/absolute/another.pdf ...]")
    exit(1)
}

var documents: [(URL, PDFDocument)] = []
for path in arguments {
    guard (path as NSString).isAbsolutePath else {
        reportError("Expected an absolute PDF path: \(path)")
        exit(1)
    }
    let url = URL(fileURLWithPath: path)
    guard let document = PDFDocument(url: url) else {
        reportError("Cannot open PDF: \(path)")
        exit(1)
    }
    guard !document.isLocked else {
        reportError("Password-protected PDF is locked: \(path)")
        exit(1)
    }
    guard document.pageCount > 0 else {
        reportError("PDF has no pages: \(path)")
        exit(1)
    }
    documents.append((url, document))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let previewDelegate = PreviewApplicationDelegate(documents: documents)
app.delegate = previewDelegate
app.run()
