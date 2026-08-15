REGEDIT.R4X
===========

REGEDIT.R4X ist das interaktive Registry-Werkzeug.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\RegEdit
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\RegEdit\zig-out\REGEDIT.R4X

Contract:
- R4XStart-Entry: `regedit_main`
- App-Klasse: `console`
- R4L-Imports: `R4DESK:Query:1`, `R4DRAW:Query:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\REGEDIT.R4X`

