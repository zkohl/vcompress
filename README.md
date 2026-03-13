# vcompress

Batch-convert H.264 video files to HEVC (H.265) using Apple's hardware-accelerated video encoding. Also supports a copy mode for backing up or replacing files. Preserves directory structure, file metadata (timestamps, Finder tags), and supports resumable encoding via a JSON state file.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon recommended (hardware HEVC encoding)
- Swift 5.9+

## Build

```bash
swift build -c release
```

The binary is at `.build/release/vcompress`.

## Usage

```bash
vcompress <source-dir> <dest-dir> [options]
```

### Options

| Flag | Description |
|------|-------------|
| `--mode <mode>` | Operating mode: `encode` (default) or `copy` |
| `--jobs <n>` | Parallel jobs, 1-64 (default: auto-detected from chip) |
| `--min-size <size>` | Skip files smaller than this, e.g. `50MB`, `1GB` |
| `--quality <tier>` | Quality tier: `standard` (default), `high`, `veryHigh`, or `max` |
| `--ignore-tags <tags>` | Skip files with any of these Finder tags (comma-separated) |
| `--include-tags <tags>` | Only include files with any of these Finder tags (comma-separated) |
| `--fresh` | Ignore existing state file; re-encode all files |
| `--dry-run` | Print the plan and exit |
| `--yes` | Skip the confirmation prompt |
| `--verbose` | Enable verbose output |
| `--json` | Output scan results as JSON (use with `--dry-run`) |

### Examples

```bash
# Encode all H.264 files, auto-detect parallelism
vcompress /Volumes/Media/Raw /Volumes/Media/Compressed

# Max quality encode, skip files under 100MB, 4 parallel jobs
vcompress /Volumes/Media/Raw /Volumes/Media/Compressed --quality max --min-size 100MB --jobs 4

# Preview what would be encoded
vcompress /Volumes/Media/Raw /Volumes/Media/Compressed --dry-run
```

## Copy Mode

Use `--mode copy` to copy files from source to destination, preserving directory structure. Unlike encode mode, copy mode operates on all files — not just videos.

Use cases:
- **Backup originals** before encoding
- **Replace originals** with compressed versions from a prior run

With `--dry-run`, copy mode shows which files would be overwritten if they already exist at the destination.

```bash
# Backup originals before encoding
vcompress /Volumes/Media/Raw /Volumes/Media/Backup --mode copy

# Preview what would be copied (shows overwrite indicators)
vcompress /Volumes/Media/Raw /Volumes/Media/Backup --mode copy --dry-run

# Copy only vcompress-tagged files back to originals
vcompress /Volumes/Media/Compressed /Volumes/Media/Raw --mode copy --include-tags "vcompress:standard"
```

## Finder Tag Filtering

Filter files by macOS Finder tags using `--ignore-tags` or `--include-tags`. These work in both encode and copy modes.

- `--ignore-tags tag1,tag2` — skip files that have any of the listed tags
- `--include-tags tag1,tag2` — only include files that have any of the listed tags

The two flags are mutually exclusive.

```bash
# Encode everything except files tagged "keep-original"
vcompress /src /dst --ignore-tags "keep-original"

# Only encode files tagged "needs-compress"
vcompress /src /dst --include-tags "needs-compress"

# Copy only vcompress-processed files
vcompress /src /dst --mode copy --include-tags "vcompress:standard"
```

## How It Works

1. **Scan** the source directory for video files (`.mov`, `.mp4`, `.m4v`)
2. **Filter** by Finder tags if `--ignore-tags` or `--include-tags` is set
3. **Classify** each file: skip if already HEVC, audio-only, below min-size, or already encoded
4. **Display** a plan summary with file counts and estimated output size
5. **Encode** files in parallel using bounded `TaskGroup` concurrency
6. **Validate** each output (file size > 0, playable)
7. **Copy metadata** (creation/modification dates, Finder tags) to the output
8. **Track state** in a JSON file for crash recovery and resumable runs

### Supported Containers

| Extension | Output Format |
|-----------|--------------|
| `.mov` | QuickTime `.mov` |
| `.mp4` | MPEG-4 `.mp4` |
| `.m4v` | MPEG-4 `.mp4` (preserves `.m4v` extension) |

### Quality Tiers

| Tier | Method | Typical Savings | Description |
|------|--------|-----------------|-------------|
| `standard` | AVAssetExportSession (HEVCHighestQuality) | ~85–95% | Apple's built-in highest quality preset |
| `high` | AVAssetReader/Writer (quality 0.65) | ~80–90% | Explicit quality control, good compression |
| `veryHigh` | AVAssetReader/Writer (quality 0.75) | ~70–85% | Higher quality, moderate compression |
| `max` | AVAssetReader/Writer (quality 0.85) | ~55–80% | Best quality, least compression |

### Auto-detected Job Count

| Chip | Default Jobs |
|------|-------------|
| M1/M2 base | 2 |
| M2 Pro, M3 Pro | 3 |
| M1 Max/Ultra, M3 Max/Ultra, M4 Max/Ultra | 4 |
| Intel | 1 |

## State File

vcompress writes a `.vcompress-state.json` file in the destination directory to track progress. This enables:

- **Resuming** interrupted encodes (files marked in-progress reset to pending on restart)
- **Skipping** already-encoded files on subsequent runs
- **Re-encoding** when switching presets (standard <-> high <-> max)

Use `--fresh` to ignore the state file and re-encode everything.

## Graceful Shutdown

Press `Ctrl+C` (SIGINT) to stop gracefully. In-progress encodes will finish, temporary files are cleaned up, and state is flushed before exit (exit code 130).

## Testing

```bash
# Run unit tests
swift test

# Generate integration test fixtures (requires ffmpeg)
ffmpeg -f lavfi -i testsrc2=duration=2:size=320x240:rate=30 \
       -f lavfi -i sine=frequency=440:duration=2 \
       -c:v libx264 -preset ultrafast -c:a aac \
       Tests/vcompressTests/Integration/Fixtures/sample_h264.mov

ffmpeg -f lavfi -i testsrc2=duration=2:size=320x240:rate=30 \
       -c:v libx265 -preset ultrafast \
       Tests/vcompressTests/Integration/Fixtures/sample_hevc.mp4

ffmpeg -f lavfi -i sine=frequency=440:duration=2 \
       -c:a aac \
       Tests/vcompressTests/Integration/Fixtures/audio_only.mov
```

## License

Private. All rights reserved.
