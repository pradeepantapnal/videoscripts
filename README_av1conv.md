# av1conv.py – Advanced AV1 batch transcoder

`av1conv.py` is a Python port of the original `av1conv.sh` automation script. It
brings the extensive feature set of the shell version into a single, maintainable
Python module while retaining the quality-first encoding pipeline that made the
project popular. The goal of the rewrite is to provide the same ergonomics –
content-aware encoding decisions, metadata preservation, audio/subtitle
management and batch friendly progress reporting – in a codebase that is easier
to extend and integrate with other tooling.

## Highlights

- **SVT-AV1 first** – automatically validates that your FFmpeg build exposes the
  `libsvtav1` encoder and configures it with sensible defaults for film, TV and
  animation content.
- **Configuration compatible** – optional `av1conv.conf` files follow the same
  `key=value` syntax as the shell script. A starter template can be generated
  with `--generate-config`.
- **Metadata aware** – carries HDR mastering display and content light metadata
  where available, preserves original colour primaries/transfer functions for
  SDR sources and keeps forced subtitle flags intact.
- **Smart track selection** – favours default audio tracks in the preferred
  language, down-mixes when requested and converts unsupported subtitle codecs
  (e.g. `mov_text`) to SRT automatically.
- **Parallel friendly** – optionally processes multiple files at a time while
  keeping per-file logging tidy.
- **Reversion safeguards** – compares the encoded result against the source and
  reverts when the AV1 output grows in size (unless `--allow-larger` is
  supplied).

## Requirements

- Python 3.9+
- FFmpeg build compiled with `libsvtav1` and either `libopus` or an AAC encoder
  (`aac` or `libfdk_aac`)
- ffprobe (normally bundled with FFmpeg)
- Optional: `mkvpropedit` if you plan to post-process Matroska files further,
  although it is not required by the script itself.

## Installation

Clone the repository and run the script directly:

```bash
python3 av1conv.py /path/to/video/library
```

Alternatively make it executable and place it somewhere on your `$PATH`:

```bash
chmod +x av1conv.py
sudo ln -s "$(pwd)/av1conv.py" /usr/local/bin/av1conv
```

## Command line usage

The interface mirrors the shell script. Run `python3 av1conv.py --help` to see
all options. The most common flags are listed below:

| Option | Description |
| --- | --- |
| `--config FILE` | Load configuration overrides from a file |
| `-v, --verbose` | Show verbose logging |
| `-c, --crf VALUE` | Override CRF target |
| `-p, --preset VALUE` | Override SVT-AV1 preset |
| `-J, --parallel N` | Number of files to encode in parallel |
| `-s, --size VALUE` | Minimum file size (e.g. `1G`, `500M`) |
| `-r, --remove` | Delete the source file after successful encode |
| `--allow-larger` | Keep AV1 encode even if it ends up larger |
| `--resize-1080p` / `--resize-720p` | Downscale large sources |
| `--stereo` | Downmix the chosen audio stream to stereo |
| `--audiobitrate 192k` | Explicitly set the audio bitrate |
| `--detect-grain` | Enable heuristic content detection and grain tuning |
| `--detect-grain-test FILE` | Analyse a single file and exit |
| `--generate-config` | Write a template `av1conv.conf` |

## Configuration file

The optional configuration file follows Bash-style `key=value` lines. A helper
is available to generate the template shown below:

```bash
python3 av1conv.py --generate-config
```

Example excerpt:

```ini
# Save this as av1conv.conf in the working directory or ~/.config/av1conv/
# Override defaults one by one
crf=26
preset=4
max_parallel_jobs=3
preferred_audio_language=eng
preferred_subtitle_language=eng
forced_subtitles_only=false
```

Configuration files are loaded from (in priority order):

1. Path provided via `--config`
2. `./av1conv.conf` (next to the script)
3. `~/.config/av1conv/av1conv.conf`
4. `~/.av1conv.conf`
5. `/etc/av1conv/av1conv.conf`

All values map to the attributes on the `Config` dataclass inside
`av1conv.py`.

## How the Python port differs from the Bash original

- The ML-based content classifier from the shell script has been replaced with
  fast heuristics that mimic the most common decisions. When
  `--detect-grain` is enabled the heuristics adjust CRF/preset selections and
  seed SVT-AV1's synthetic grain strength.
- Track manipulation is performed directly through FFmpeg (`-disposition`
  flags) rather than via `mkvpropedit`, simplifying dependencies.
- Temporary directories are managed with Python's `tempfile` module and are
  cleaned automatically (unless `--keep-temp` is specified).
- Instead of interactive terminal UI components, progress is reported through
  structured log messages to keep the implementation dependency free.

## Working with the results

Encoded files are written next to the source with an `.av1.mkv` suffix. Original
files are retained unless `--remove` is provided. The script automatically skips
files that already follow the `.av1.mkv` naming convention.

Every run prints a summary containing the number of processed titles, skipped
items and the total storage savings. Use `--generate-report` to emit the same
information in JSON format for automation pipelines.

## Tips

- Ensure your FFmpeg build is recent (6.1 or newer) for best SVT-AV1
  performance.
- Consider running a single-file dry run with `--detect-grain-test` to inspect
  how the heuristics classify a source before a long batch job.
- Pair the script with a scheduler (cron/systemd timers) to keep media libraries
  automatically optimised.

## Troubleshooting

- **`libsvtav1` not found** – the script verifies encoder availability at start
  up. Install a build such as `ffmpeg-n4.4-svtav1` or Jellyfin's custom FFmpeg
  package.
- **Audio encoder errors** – ensure either `libopus` or an AAC encoder is
  available; the script defaults to Opus when present.
- **Permission denied** – check both the media directory and temporary
  directory root (defaults to `/tmp`) are writable by the user running the
  script.

## License

The Python implementation inherits the repository's MIT license. See
[LICENSE](LICENSE) for details.
