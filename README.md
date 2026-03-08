# vcompress

Batch-convert H.264 video files to HEVC (H.265) using Apple's hardware-accelerated video encoding. Preserves directory structure, file metadata (timestamps, Finder tags), and supports resumable encoding via a JSON state file.

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
| `--jobs <n>` | Parallel encode jobs, 1-64 (default: auto-detected from chip) |
| `--min-size <size>` | Skip files smaller than this, e.g. `50MB`, `1GB` |
| `--quality <tier>` | Quality tier: `standard` (default), `high`, or `max` |
| `--fresh` | Ignore existing state file; re-encode all files |
| `--dry-run` | Print the encoding plan and exit |
| `--yes` | Skip the confirmation prompt |
| `--verbose` | Enable verbose output |

### Examples

```bash
# Encode all H.264 files, auto-detect parallelism
vcompress /Volumes/Media/Raw /Volumes/Media/Compressed

# Max quality encode, skip files under 100MB, 4 parallel jobs
vcompress /Volumes/Media/Raw /Volumes/Media/Compressed --quality max --min-size 100MB --jobs 4

# Preview what would be encoded
vcompress /Volumes/Media/Raw /Volumes/Media/Compressed --dry-run
```

## How It Works

1. **Scan** the source directory for video files (`.mov`, `.mp4`, `.m4v`)
2. **Classify** each file: skip if already HEVC, audio-only, below min-size, or already encoded
3. **Display** a plan summary with file counts and estimated output size
4. **Encode** files in parallel using bounded `TaskGroup` concurrency
5. **Validate** each output (file size > 0, playable)
6. **Copy metadata** (creation/modification dates, Finder tags) to the output
7. **Track state** in a JSON file for crash recovery and resumable runs

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
| `max` | AVAssetReader/Writer (quality 0.75) | ~70–85% | Best quality, least compression |

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
