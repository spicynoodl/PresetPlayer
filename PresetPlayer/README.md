# PresetPlayer
Music player for iPhone with a parametric EQ. Import your own music, then load EasyEffects (.json) or AutoEQ / Equalizer APO (.txt) presets.

## Repo layout (important)
`Sources/`, `project.yml` and `.github/` must be at the ROOT of the repo, not inside another folder.

## Build the IPA (no Mac)
1. Push these files to a new GitHub repo.
2. Actions > "Build unsigned IPA" > Run workflow.
3. Download the PresetPlayer-ipa artifact and sideload with AltStore / Sideloadly / TrollStore.

## Adding music
- In the app: Library > + > Add files or folder.
- Or the Files app > On My iPhone > PresetPlayer > Music (drop files there), then Library > + > Rescan.
- Formats: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF.

## Limits
- Plays only music inside the app (iOS has no system-wide EQ).
- Not bit-perfect or gapless: audio is resampled by iOS. No DRM / Apple Music tracks.
