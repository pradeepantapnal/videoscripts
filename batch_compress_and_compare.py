#!/usr/bin/env python3
"""
batch_compress_and_compare.py  (v3.0.0)
---------------------------------------
1) Finds video files (by extension) in the current directory.
2) Uses ffmpeg to compress each into AV1 (libsvtav1) + Opus audio.
3) Uses ffprobe to extract metadata from both the original and compressed files.
4) Prints a side-by-side comparison: duration, codecs, resolution, bitrate, file size.
5) Moves original → ./over/    and    compressed → ./output/

Usage:
    python batch_compress_and_compare.py
"""

import subprocess
import shutil
import time
import json
from pathlib import Path
from datetime import datetime

# ------------------------------------------------------------------------
#  CONFIGURATION
# ------------------------------------------------------------------------

FFMPEG_CMD = "ffmpeg"
FFPROBE_CMD = "ffprobe"

# Video-encoding options:
VIDEO_OPTIONS = [
    "-c:v", "libsvtav1",
    "-threads", "8",
    "-crf", "22",
    "-g", "240",
    "preset", "6",
    "aq-mode", "3",
    "-svtav1-params", "tune=0:enable-overlays=1:scd=1",
    "-pix_fmt", "yuv420p10le",
    "-c:a", "libopus",
    "-b:a", "100k",
]

METADATA_OPTIONS = [
    "-metadata", "comment=Encoded by Pradeep"
]

VIDEO_EXTENSIONS = [
    ".avi", ".mpg", ".mp4", ".flv", ".3gp",
    ".mkv", ".wmv", ".mov", ".mts", ".vob", ".webm"
]

DIR_OVER = Path("over")
DIR_OUTPUT = Path("output")


# ------------------------------------------------------------------------
#  HELPERS: ffprobe + human-readable formatting
# ------------------------------------------------------------------------

def human_readable_size(bytes_size: int) -> str:
    """Convert a size in bytes to megabytes (2 decimal places)."""
    mb = bytes_size / (1024 * 1024)
    return f"{mb:.2f} MB"


def run_ffprobe(path: Path) -> dict:
    """
    Run ffprobe on 'path' and return a JSON-parsed dict containing
    both 'format' and 'streams' sections.
    """
    cmd = [
        FFPROBE_CMD,
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        str(path)
    ]
    try:
        output = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        return json.loads(output)
    except subprocess.CalledProcessError:
        return {}


def extract_summary(probe_info: dict) -> dict:
    """
    Given the dict from run_ffprobe, pull out:
      - duration (in seconds, float)
      - overall bitrate (in bits/sec, int; may be None)
      - file_size (in bytes, int; may be None)
      - video_codec, width, height
      - audio_codec
    Returns a dict of these five fields (some may be None if missing).
    """
    summary = {
        "duration": None,
        "bit_rate": None,
        "file_size": None,
        "video_codec": None,
        "width": None,
        "height": None,
        "audio_codec": None
    }

    # 'format' section
    fmt = probe_info.get("format", {})
    if fmt:
        summary["duration"] = float(fmt.get("duration", 0.0)) if fmt.get("duration") else None
        summary["bit_rate"] = int(fmt.get("bit_rate")) if fmt.get("bit_rate") else None
        summary["file_size"] = int(fmt.get("size")) if fmt.get("size") else None

    # 'streams' section: look for the first video stream and first audio stream
    streams = probe_info.get("streams", [])
    for s in streams:
        if s.get("codec_type") == "video" and summary["video_codec"] is None:
            summary["video_codec"] = s.get("codec_name")
            summary["width"] = s.get("width")
            summary["height"] = s.get("height")
        elif s.get("codec_type") == "audio" and summary["audio_codec"] is None:
            summary["audio_codec"] = s.get("codec_name")
        # once we have both, we can break
        if summary["video_codec"] and summary["audio_codec"]:
            break

    return summary


def print_comparison(orig_path: Path, comp_path: Path):
    """
    Use ffprobe on both orig_path and comp_path, then print a side-by-side summary:
      • Duration
      • Bitrate
      • File size
      • Video codec + resolution
      • Audio codec
    """
    print("  ↳ Running ffprobe on both files for comparison…")

    orig_info = run_ffprobe(orig_path)
    comp_info = run_ffprobe(comp_path)

    orig_sum = extract_summary(orig_info)
    comp_sum = extract_summary(comp_info)

    # Header
    headers = [
        "Property",
        "Original",
        "Compressed"
    ]
    rows = []

    # Duration (secs → HH:MM:SS)
    def format_dur(sec):
        if sec is None:
            return "N/A"
        h = int(sec // 3600)
        m = int((sec % 3600) // 60)
        s = int(sec % 60)
        return f"{h:02d}:{m:02d}:{s:02d}"

    rows.append([
        "Duration",
        format_dur(orig_sum["duration"]),
        format_dur(comp_sum["duration"])
    ])

    # Bitrate (bits/sec → Mbps)
    def format_bitrate(b):
        if b is None:
            return "N/A"
        mbps = b / (1_000_000)
        return f"{mbps:.2f} Mbps"

    rows.append([
        "Bitrate",
        format_bitrate(orig_sum["bit_rate"]),
        format_bitrate(comp_sum["bit_rate"])
    ])

    # File size
    rows.append([
        "File size",
        human_readable_size(orig_sum["file_size"]) if orig_sum["file_size"] else "N/A",
        human_readable_size(comp_sum["file_size"]) if comp_sum["file_size"] else "N/A"
    ])

    # Video codec + resolution
    def format_video_codec(codec, w, h):
        if codec is None:
            return "N/A"
        if w and h:
            return f"{codec} ({w}×{h})"
        return codec

    rows.append([
        "Video codec & res",
        format_video_codec(orig_sum["video_codec"], orig_sum["width"], orig_sum["height"]),
        format_video_codec(comp_sum["video_codec"], comp_sum["width"], comp_sum["height"])
    ])

    # Audio codec
    rows.append([
        "Audio codec",
        orig_sum["audio_codec"] or "N/A",
        comp_sum["audio_codec"] or "N/A"
    ])

    # Print as a simple table
    col_widths = [
        max(len(r[0]) for r in rows) + 2,
        max(len(r[1]) for r in rows) + 2,
        max(len(r[2]) for r in rows) + 2,
    ]

    # Print header
    print()
    print(
        f"    {headers[0].ljust(col_widths[0])}"
        f"{headers[1].ljust(col_widths[1])}"
        f"{headers[2].ljust(col_widths[2])}"
    )
    print("    " + "-" * (sum(col_widths) + 2))
    for r in rows:
        print(
            f"    {r[0].ljust(col_widths[0])}"
            f"{r[1].ljust(col_widths[1])}"
            f"{r[2].ljust(col_widths[2])}"
        )
    print()


# ------------------------------------------------------------------------
#  MAIN COMPRESSION + COMPARISON LOGIC
# ------------------------------------------------------------------------

def process_video(input_path: Path):
    """
    1) Runs ffmpeg to compress into AV1/Opus → temp file
    2) If ffmpeg succeeded, runs ffprobe on both original & compressed
       and prints a comparison.
    3) Moves original → over/, compressed → output/
    """
    print("\n" + "_" * 100)
    print(f"Processing: {input_path.name}")

    # 1) Get original file size and timestamp
    try:
        orig_size = input_path.stat().st_size
    except FileNotFoundError:
        print(f"  [Error] File not found: {input_path}")
        return

    # Build unique temp filename
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    temp_filename = f"{input_path.stem}_{timestamp}.mp4"
    temp_path = Path(temp_filename)

    # Build a log file name
    log_filename = f"{input_path.stem}_{timestamp}.log"
    log_path = Path(log_filename)

    # Assemble ffmpeg command
    cmd = [
        FFMPEG_CMD,
        "-hide_banner",
        "-loglevel", "info",
        "-report",
        "-y",
        "-i", str(input_path),
        *VIDEO_OPTIONS,
        *METADATA_OPTIONS,
        str(temp_path)
    ]

    # Run ffmpeg, logging stdout/stderr into our custom log file
    with log_path.open("wb") as lf:
        start = time.perf_counter()
        result = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT)
        elapsed = time.perf_counter() - start

    if result.returncode != 0:
        print(f"  [FFmpeg Error] exited with code {result.returncode}. Check log: {log_path}")
        # Optionally show first few lines:
        with log_path.open("r", errors="ignore") as lf:
            for i, line in enumerate(lf):
                if i >= 5:
                    break
                print(f"    {line.rstrip()}")
        return

    # 2) Report timing and size info
    print(f"  → Compression completed in {elapsed:.1f} sec")
    print(f"  • Original size  : {human_readable_size(orig_size)}")

    try:
        comp_size = temp_path.stat().st_size
    except FileNotFoundError:
        print(f"  [Error] Compressed file not found: {temp_path}")
        return

    print(f"  • Compressed size: {human_readable_size(comp_size)}")

    # 3) Run ffprobe comparison
    print_comparison(input_path, temp_path)

    # 4) Move files:
    target_over = DIR_OVER / input_path.name
    if target_over.exists():
        target_over.unlink()
    shutil.move(str(input_path), str(target_over))
    print(f"  ✔ Moved original to: {target_over}")

    final_name = f"{input_path.stem}.mp4"
    target_out = DIR_OUTPUT / final_name
    if target_out.exists():
        target_out.unlink()
    shutil.move(str(temp_path), str(target_out))
    print(f"  ✔ Moved compressed to: {target_out}")


def main():
    # Ensure folders exist
    DIR_OVER.mkdir(exist_ok=True)
    DIR_OUTPUT.mkdir(exist_ok=True)

    cwd = Path.cwd()
    video_files = []

    # Gather all extensions (case-insensitive)
    for ext in VIDEO_EXTENSIONS:
        video_files.extend(cwd.glob(f"*{ext}"))
        video_files.extend(cwd.glob(f"*{ext.upper()}"))

    if not video_files:
        print("No video files found.")
        return

    video_files = sorted(video_files)

    for idx, vid in enumerate(video_files, start=1):
        print(f"\n>>> ({idx}/{len(video_files)})")
        process_video(vid)

    print("\n" + "_" * 60)
    print("Batch job completed at:", datetime.now().strftime("%d/%m/%Y %H:%M:%S"))


if __name__ == "__main__":
    main()

