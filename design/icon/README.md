# Blackbird icon

- `BlackbirdIcon.svg` — master vector source.
- `Blackbird-1024.png` — 1024×1024 raster master, exported from the SVG.
- `Blackbird.iconset/` — 16–512 @1x/@2x PNGs required by `iconutil`.

## Regenerating the shipped `.icns`

```sh
iconutil -c icns \
  -o Sources/Blackbird/Resources/AppIcon.icns \
  design/icon/Blackbird.iconset
```

The resulting file has all 10 blocks (`ic04`–`ic14`), so Stage Manager, the Dock,
and Finder can render the app tile at every size. The app's `CFBundleIconFile`
key in `project.yml` points at this file.
