<img src="Resources/icon-preview.png" width="96" alt="Exif icon">

# Exif

Exif removes the metadata hidden in photos, videos and PDFs (camera, GPS location, dates, author, software…) before you share them. Drop files or folders on the window: each file is cleaned, and the list shows how many tags it had before and after.

Exif is a native macOS version of [ExifCleaner](https://github.com/szTheory/exifcleaner) by szTheory. It works the same way, with the same layout, options, texts and ExifTool commands; it is in English only, and the window, icons, colours and appearance (light or dark) follow macOS and the rest of the suite, and it starts much faster.

## How it works

- **Add files**: drop files or folders on the window or the Dock icon, use **Choose files** (⌘O) / **Choose folder** (⇧⌘O), the + and folder buttons in the toolbar, or *Open With › Exif* in Finder. Folders are searched inside, and their files are listed under the folder's row (collapsible). Unsupported files are skipped, and a message says how many.
- **The list**: name, type, size (before → after), tags before and after; the name column takes whatever width the window has, the other four keep theirs on the right, centred; a ✓ when the file was cleaned. Under the name: *Written to a copy*, or why a file was left alone (no metadata found, nothing removable, RAF refused, an error). Click a row to see its metadata grouped (Camera, Location, Time, Author, Image, Color profile…): what was removed and what was kept, with **Copy all**. The arrow on the right shows the file in Finder.
- **Status bar**: "*n* of *m* cleaned — *x* tags removed — *s* s", and **Clear**. The Dock icon shows how many files are left while it works.
- **Settings** (Exif › Settings…, ⌘,), in a settings window of their own as in the other apps of the suite, saved at once:

| Setting | Default | |
| --- | --- | --- |
| Preserve orientation | on | keeps photos upright |
| Preserve color profile | on | keeps the ICC profile |
| Preserve resolution | on | keeps the DPI |
| Save as copy | on | writes `name_cleaned.ext` (`_cleaned_2`…) and leaves the original untouched |
| Preserve modification date | off | |
| Remove macOS attributes | off | quarantine, download origin, Finder tags |

Supported: JPEG, PNG, GIF, TIFF, WebP, HEIC/HEIF, BMP, AVIF, SVG, RAW (CR2, CR3, NEF, ARW, ORF, RW2, DNG, PEF, SRW; RAF is refused, as ExifCleaner does, because cleaning it isn't safe yet), MP4, MOV, AVI, M4A, M4V, 3GP, WMV, PDF.

The cleaning is ExifCleaner's: `exiftool -all=`, plus the QuickTime dates for video, `-CommonIFD0=` for TIFF, the identifying RAW tags (serials, owner, capture dates) for RAW, and `-TagsFromFile @` for what the settings keep. Tags are counted the way ExifCleaner counts them (file system and structural values left out, duplicates included); the counts were checked against ExifCleaner's own algorithm on its test files. PDFs go one step further than in ExifCleaner. ExifTool writes a PDF's changes as an update appended to the file, so on its own the old values are only hidden and `exiftool -PDF-update:all= FILE` brings them back. After ExifTool, Exif writes the PDF again from scratch with macOS's PDFKit (pages, links, bookmarks and annotations kept; earlier versions of the file dropped), then, without moving a byte, empties the document information PDFKit adds (macOS build, time of cleaning) and the Exif, XMP, Photoshop/IPTC and comment segments of the JPEG images inside it. Before it replaces the original or the copy, the new file is checked: it opens; every page has the same size, links, notes and form fields; the bookmarks are the same; no XMP is left; and every page has the same text, or, where a font's character map didn't come through, still looks the same (then the row says that some text may no longer copy or search correctly; on the TCPDF certificates this is the "Powered by TCPDF" footer). If a check fails, the ExifTool result stays and the row says so. Signed PDFs aren't rewritten, since that would break the signature. The new file is unencrypted (an owner password's restrictions are dropped) and PDF 1.3. Not removed: metadata in images that aren't JPEG, and anything the visible content shows. A PDF whose XMP packet can't be read (encrypted PDFs made by TCPDF, for example) is still cleaned: the unreadable packet goes with the rest.

macOS adds a `com.apple.provenance` attribute to the files apps write (it names, by number, the app that wrote the file); it holds no personal data and macOS doesn't let apps remove it, so **Remove macOS attributes** leaves it, and a cleaned file or copy still has it.

## What changed from ExifCleaner

| | ExifCleaner 4.7 | Exif |
| --- | --- | --- |
| App | Electron (Chromium + Node), React | native SwiftUI, 23 MB |
| First launch (measured on this Mac) | 2.2 s to the window | 0.34 s |
| Window | web page in a window, drawer for settings, 26 languages | macOS window with unified toolbar, a settings window, system controls; English only |
| Files at once | one ExifTool process, files one after the other | up to four ExifTool processes, files in parallel |

ExifTool (Perl) starts in the background right after the window opens, so neither the launch nor the first file waits for it, and it stays open between files (`-stay_open`). 13 sample files of every kind are cleaned in about 0.4 s.

## Tools inside the app

`Contents/Resources/exiftool` holds ExifTool 13.59 by Phil Harvey (the version ExifCleaner 4.7 bundles), unchanged: the `exiftool` script and its `lib` folder, run by macOS's `/usr/bin/perl`. `scripts/fetch-tools.sh` downloads it from exiftool.org (or SourceForge) and checks its SHA-256. ExifTool is free software under the same terms as Perl (Artistic License or GPL).

`Resources/strings.json` holds ExifCleaner's English texts, taken from its translation file.

## Building

```
scripts/setup-signing.sh   # once: local signing identity in signing/
scripts/build-app.sh       # downloads ExifTool if needed, builds, signs, installs in /Applications
scripts/make-dmg.sh        # installer: build/Exif-<version>.dmg
```

Apple Silicon, macOS 15 or later. `scripts/make-icon.swift` draws the icon.

Test modes:

```
EXIF_TOOLS=vendor/exiftool .build/debug/Exif --clean FILE...      # no window: counts and outcome per file, total time
EXIF_TRACE=1 build/Exif.app/Contents/MacOS/Exif                  # launch timings
open --env EXIF_SNAPSHOT=<dir> [--env EXIF_OPEN=a:b:c] [--env EXIF_SNAPSHOT_EXPAND=<n>] build/Exif.app   # PNG of each window every second
```

## License

MIT, as ExifCleaner (see `LICENSE`): © szTheory, and © 2026 bennhouse for this version.
