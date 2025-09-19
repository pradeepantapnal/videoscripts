# Video Scripts

Set of python scripts to process audio and video files.

## `findOptimumBitrate.py`

This helper inspects one or more video files with `ffprobe` and suggests a
bitrate that should preserve quality for re-encoding.

### Command line usage

```bash
python findOptimumBitrate.py /path/to/video.mp4
```

Key options:

- `--json` – emit the full analysis report as JSON.
- `--target-bpp` – tweak the desired bits-per-pixel value used for the bitrate
  calculation (default: `0.085`).
- `--minimum` / `--maximum` – clamp the recommendation to a specific range.
- `--ffprobe` – point to a custom `ffprobe` binary (falls back to the
  `FFPROBE` environment variable or just `ffprobe`).

### Programmatic usage

You can import the module and call the helpers directly:

```python
from findOptimumBitrate import analyse_path, AnalysisConfig

result = analyse_path("video.mp4", AnalysisConfig(target_bpp=0.1))
print(result.recommendation)
```

Each `AnalysisResult` contains the parsed `ffprobe` metadata (`result.probe`),
the recommended bitrate in bits per second (`result.recommendation`), and any
error message if the bitrate could not be determined (`result.error`).
