# Native PDFKit preview validation

Run the automated checks from this checkout:

```bash
node --test tests/quicklook.test.cjs
./build.sh
./pdfpreview --self-test
```

The JavaScript tests check preview lifecycle and export behavior with controlled test doubles. The native self-test checks PDFKit selection, copying, and annotation handling using synthetic PDFs. It also checks actual visible page geometry for A4, Letter, landscape, rotated, cropped, and very tall pages: ordinary first pages fit completely, and tall pages start at the top within a window whose height is capped by the available screen space. Both complement the live Zotero checks below.

An isolated headless smoke test of version `1.0.11b1` on Zotero 10.0.4 (2026-09-25) loaded the package's JavaScript from its XPI, deployed the bundled `pdfpreview` helper, and passed a synthetic PDF attachment with a saved Zotero highlight through `_getAnnotatedPDFPath` and the real `Zotero.PDFWorker.export`. PDFKit found one highlight and the original selectable text in the exported PDF. The original PDF bytes were unchanged, and the annotation remained in Zotero. The test used separate temporary profile and data directories and exited successfully. It did not exercise the installed plugin's menus, interactive selection, or focus behavior in the Zotero UI.

Build with `./build.sh`, install `zoteroquicklookmac-1.0.11b3.xpi` in Zotero, and restart Zotero. These checks require a real Zotero library and the installed plugin; successful compilation alone does not verify them.

- Select an attachment with selectable PDF text and saved Zotero highlights. Press **Space**. Confirm that the native PDF window opens, the highlights match Zotero, and selecting text then pressing **⌘C** copies the selected text into another app.
- Preview A4, Letter, and landscape PDFs, including rotated and cropped pages. Confirm that both the top and bottom of the first page are visible immediately and that the window adapts to the page's dimensions while staying within the available screen area.
- Scroll to the second and later pages of a multipage PDF. Confirm that the gap between consecutive pages matches the left and right margins.
- Preview a very tall PDF, such as a full webpage screenshot. Confirm that it opens at the top with a readable width, the window height stays within the available screen area, and scrolling reaches the rest of the page.
- Zoom in and out, scroll to a later page, and resize the window. Confirm that subsequent interaction does not reset the preview to the top or restore the initial zoom unexpectedly.
- Repeat from the PDF's parent item. Test both highlights stored only in Zotero and annotations already embedded in a PDF. Confirm there are no duplicate annotations, and confirm the original PDF's bytes and modification time are unchanged after previewing.
- Add, change, or remove a highlight in Zotero, save it, then close and reopen the preview. Confirm that the new preview reflects the current annotations.
- Close the preview with **Space**, **Escape**, **⌘Y**, and the window's close button. Repeat with the PDF window focused and with Zotero focused. Verify that keyboard focus returns normally and that **⌘C** never closes the window.
- Toggle rapidly while a preview is being prepared, then select a different PDF and preview it. Confirm that closed PDFs do not reopen, a new preview replaces the previous one, and temporary exports are cleaned up when all preview windows close.
- Check a large PDF, a scanned PDF without a text layer, and a PDF with copying restricted. Verify that they display, with copying available only where the PDF permits it.
- Preview an image, an EPUB, and a note (**Shift+Space**). Confirm that the existing QuickLook paths still work. Check a PDF contact sheet (**Option+Space**) and its close shortcuts.
- Preview a synced PDF that has not been downloaded. Confirm that Zotero retrieves it before opening the preview.
- While a PDF preview is open, disable the plugin or quit Zotero. Confirm that the helper exits and temporary preview files are removed. Re-enable or restart and confirm that another preview opens successfully.
- Repeat on Intel and Apple silicon if both machines are available, and on each Zotero major version claimed as supported before a stable release.

Record the macOS and Zotero versions used and any failures. Building this branch does not publish it or modify the stable update feed.
