# ZoteroQuickLookMac

A macOS plugin for Zotero 7–10 that lets you preview attachments by pressing **Space** — just like in Finder.

PDFs open in a native macOS PDFKit window. You can select text and copy it with **⌘C**, and the preview includes Zotero's saved PDF annotations, including highlights. Other attachment types use macOS QuickLook.

Previously named Zotero7QuickLook. Installing ZoteroQuickLookMac updates the existing plugin in place.

Spiritual successor to [ZoteroQuickLook](https://github.com/mronkko/ZoteroQuickLook), which supported Zotero 4–6 but broke with Zotero 7's new plugin architecture.

![ZoteroQuickLookMac screenshot](docs/screenshot.png)

## Features

- **Space** — Toggle preview on the selected item (prefers PDF, then EPUB, over other attachments)
- **Shift+Space** — Preview the notes attached to the selected item
- **Option+Space** — Preview a PDF as a contact sheet (grid of all page thumbnails, adaptive layout for few-page PDFs)
- **Cmd+Y** — Alternative toggle shortcut
- **Escape** — Close the preview
- **Right-click → Quick Look** — Context menu entry
- **Right-click → Quick Look Contact Sheet** — Context menu entry for contact sheet
- PDF previews support selecting text and copying it with **⌘C**
- PDF previews include Zotero annotations exported into a fresh temporary PDF for each preview; the original PDF is not edited
- PDF windows adapt to the first page's dimensions and available screen space, showing a normal first page in full. Very tall PDFs, such as full webpage screenshots, open at the top with a readable width and a capped window height; scroll to see the rest
- The gap between PDF pages matches the side margins
- Works with PDFs, images, HTML, EPUBs, and any file type that macOS QuickLook supports
- Selecting a parent item previews its PDF attachment; falls back to EPUB, then to the first available attachment
- EPUB files are rendered on the fly into a single styled HTML page (Palatino, 80 px margin, book-width column), with the book's own stylesheets loaded so layout and typography are preserved
- Notes are rendered as HTML and previewed
- Synced files that aren't downloaded locally are fetched automatically

## Requirements

- **macOS 12 (Monterey)** or later (Intel or Apple silicon)
- **Zotero 7, 8, 9, or 10.x**

## Installation

1. Download the `.xpi` file from the [latest release](https://github.com/gchapron/ZoteroQuickLookMac/releases/latest).
2. In Zotero, go to **Tools → Plugins** (called **Add-ons** in older versions)
3. Click the gear icon → **Install Add-on From File...**
4. Select the downloaded `.xpi` file
5. Restart Zotero

## Building from source

Requires macOS and Xcode Command Line Tools. From the repository checkout, run:

```bash
./build.sh
```

The script compiles both Swift helpers (`contactsheet` and `pdfpreview`) for Apple silicon and Intel, targeting macOS 12. It uses temporary compiler caches, combines the architectures into universal binaries, and packages an explicit list of runtime files with normalized archive timestamps. Temporary build files are removed on exit. The generated helpers and `.xpi` are ignored by Git.

The package name follows the manifest version: `zoteroquicklookmac-1.0.11.xpi`. Install it in Zotero as described above. Building does not commit, push, publish a release, or update the stable update feed. See [the manual validation checklist](docs/testing.md) before publishing.

## How it works

The plugin registers a keyboard listener on Zotero's items tree. When you press Space, it resolves the selected item's attachment. For PDFs, it exports a temporary copy with Zotero's saved annotations and opens it in the bundled `pdfpreview` helper, which uses Apple's PDFKit. Each preview gets a fresh export so saved annotation changes appear when you reopen it. The original attachment is left unchanged.

PDFKit provides text selection and the standard **⌘C** copy command. **Space**, **Escape**, and **⌘Y** close the PDF window, including when that window has focus. The helper is a separate process managed by the plugin.

The initial window size and zoom use the first page's visible dimensions, including its crop and rotation. Normal pages fit completely within the available screen space. Very tall pages keep a readable width while the window height is capped, and the preview starts at the top. The gap between consecutive pages matches the side margins. You can then scroll, resize the window, or change the zoom normally.

For other attachment types, the plugin launches `/usr/bin/qlmanage -p <file>` and retains the subprocess handle so the preview can be closed with the toggle shortcuts.

EPUB previews are produced on the fly because macOS QuickLook doesn't render EPUBs natively. The plugin unzips the archive into a temp directory, parses `META-INF/container.xml` and the OPF manifest to walk the spine in reading order, then concatenates each chapter's `<body>` into a single HTML document. The book's own stylesheets (linked and inline) are pulled in so the original layout is preserved, with a Palatino base font, 80 px margin, and 720 px book-width column applied on top. Relative URLs in markup and CSS are rewritten to absolute `file://` paths so images, fonts, and inline SVGs resolve.

The contact sheet feature (Option+Space) uses a pre-compiled universal binary (arm64 + x86_64) that renders all PDF pages as thumbnails in a scrollable HTML grid using CoreGraphics. The binary is bundled in the `.xpi` and deployed to a temp directory on first use. The generated HTML file is then previewed via QuickLook. The layout adapts to the number of pages: PDFs with few pages (1–4) use fewer columns and higher-resolution thumbnails so they fill the preview width instead of leaving empty space.

## Limitations

- Copying requires an existing text layer. Scanned image-only PDFs need OCR first, and a PDF's copy restrictions still apply.
- Native text selection, annotations, and page-aware window sizing apply to PDF previews. EPUB and note previews continue to use QuickLook.
- Contact sheets remain image-based thumbnails; their text cannot be selected.
- The native PDF preview is for reading and copying. Edit annotations in Zotero, save them, and reopen the preview to see the changes.

## License

MIT
