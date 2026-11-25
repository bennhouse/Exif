# Changelog

## Unreleased

- No scroll bars in lists (with "Always show" they took space and changed the lists' width).
- Settings in a window of their own (Exif › Settings…, ⌘,) with only the cleaning options; no settings button in the status bar, no drawer.
- Appearance always follows the system (the Light/Auto/Dark choice is gone).
- English only: the language setting and the other 25 translations are gone.
- File list: type, size, before and after are centred in fixed columns on the right; the name takes the rest of the width.
- PDFs are written again from scratch after ExifTool (PDFKit), so the removed values can no longer be recovered with `exiftool -PDF-update:all=`; the JPEG images inside also lose their Exif/XMP/Photoshop segments. The new file is checked (pages, links, form fields, bookmarks, text) before it replaces anything; if that step fails, or the PDF is signed, the row says the PDF was cleaned by ExifTool only.
- Save as copy no longer fails on a file ExifTool has nothing to change in ("1 image files copied"): the copy is made.
- A PDF's tag count leaves out the standard sRGB colour profile PDFKit writes.
- PDFs with an unreadable XMP packet (encrypted PDFs made by TCPDF, such as course certificates) are cleaned instead of failing with "XMP format error (no closing tag for …)".

## 1.0

First release: ExifCleaner 4.7 rewritten as a native macOS app.

- Same layout, options, texts and 26 translations as ExifCleaner; same ExifTool 13.59 and cleaning commands; same tag counts.
- macOS window with unified toolbar (Choose files, Choose folder), settings in an inspector beside the list, status bar with the summary and Clear, Dock badge while working.
- Folders are listed under a collapsible row; click a file to see its metadata grouped, removed and kept, with Copy all.
- Fast: native launch (0.34 s instead of 2.2 s for the first launch), ExifTool started in the background and kept open, up to four files cleaned at once.
