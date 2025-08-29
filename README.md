
# PolySplit

PolySplit splits **polywav** and **AIFF** files into **per‑channel mono WAVs** with clean, sortable names. It reads human‑friendly channel labels from a `channels.txt` file, matches source bit depth automatically, and includes a **safe overwrite flow** with backup/overwrite/new/resume modes. macOS 15.5 compatible.

## Highlights
- Pan‑based splitting for broad FFmpeg compatibility.
- Auto‑detects channel count and chooses the best WAV codec to match input (16‑bit, 24‑bit, 32‑bit, float).
- Channel labels from a simple `channels.txt` (comments supported).
- **Reliability and safety:** typed confirmation for deletes, `--dry-run` preview, `resume` mode, and a `backup` mode that preserves existing output by renaming it.
- **Parallel** processing via `--workers N` with sensible defaults from your CPU.
- Flexible layouts: `flat` (all files in one folder) or `folders` (per‑source subfolder).
- Clean file names like `01_KICK_SONG1.wav` or `SONG1_01_KICK.wav` depending on the layout.

## Install
Requires FFmpeg.

```bash
brew install ffmpeg
```

Download `polysplit.sh` and make it executable:

```bash
chmod +x polysplit.sh
```

## channels.txt format
One label per line, optional comments with `#`. Blank lines ignored.

```text
# Example
Kick
Snare Top
Snare Bottom
OH L
OH R
Bass DI
GTR L
GTR R
Vox
```
The number of non‑comment lines **must** equal the channel count of your polywavs.

## Usage
Basic:

```bash
./polysplit.sh --src "/path/to/source" --out "/path/to/output" --channels "/path/to/channels.txt"
```

Layout:

- `--layout flat` (default), file names like `SOURCE_01_KICK.wav`.
- `--layout folders`, files in `--out/SOURCE/01_KICK_SOURCE.wav`.

Modes:

- `--mode new` (default), auto‑rename the output root if it already exists.
- `--mode backup`, rename existing output to `...__backup_YYYYMMDD-HHMMSS` first.
- `--mode overwrite`, delete existing output after a typed `DELETE` confirmation (or `--yes` for non‑interactive).
- `--mode resume`, keep what is already exported and only write missing files.

Examples:

```bash
# Dry‑run preview
./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt" --dry-run

# Overwrite with typed confirmation (interactive)
./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt" --mode overwrite

# Overwrite non‑interactively (e.g., CI)
./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt" --mode overwrite --yes

# Backup then run 4 files in parallel using per‑file folders
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode backup --layout folders --workers 4

# Resume and skip files that already exist
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode resume
```

## Output layout
For each source file, PolySplit writes mono WAVs named based on your chosen layout:

```
# --layout folders
OUT/SOURCE/01_KICK_SOURCE.wav
OUT/SOURCE/02_SNARE_TOP_SOURCE.wav

# --layout flat
OUT/SOURCE_01_KICK.wav
OUT/SOURCE_02_SNARE_TOP.wav
```

Bit depth and format are auto‑matched to the source. BWF/iXML metadata is preserved when your ffmpeg build supports it.

## Safeties
- **Destructive operations require confirmation.** `overwrite` deletes only after you type `DELETE` or pass `--yes`.
- **Backup mode.** `backup` preserves your previous results by renaming the existing output directory before writing.
- **DRY RUN.** `--dry-run` shows every directory create and every file that would be written.
- **Strict channel count check.** If `channels.txt` does not match the source channel count, PolySplit stops and tells you what to fix.
- **Non‑empty path guard.** Refuses to delete `/` or `.` and requires a non‑empty target path.

## Performance
- Use `--workers N` to process multiple files in parallel. On Apple silicon, `--workers 4` or `--workers 8` is a good starting point.
- Fast SSD output makes a big difference for large sessions.

## Why the rename?
This project was previously called **polywav‑split‑macos**. The new name, **PolySplit**, pairs with **TapeShift** stylistically.

## License
MIT, see `LICENSE`.
