#!/usr/bin/env python3
"""
batch_two_pass_libsvtav1_with_progress.py  (v1.1.0)
----------------------------------------------------

Two-pass AV1 (VBR) + Opus archival pipeline using FFmpeg’s libsvtav1,
with real-time progress printing for both passes.

1) Finds all video files in the current directory (by extension).
2) Pass 1: libsvtav1 analysis-only (no audio) → VBR mode (-rc 2),
          writing internal stats to "<stem>_<ts>_svp-0.log".
3) Pass 2: libsvtav1 encode AV1 + Opus (using pass-logs) → "<stem>_<ts>.mp4".
4) Prints real-time FFmpeg progress for each pass (frame/fps/time/size).
5) Runs ffprobe on both original and compressed, printing a side-by-side table:
     • Duration
     • Bitrate
     • File size
     • Video codec & resolution
     • Audio codec
6) Moves original → "./over/"  and compressed → "./output/".
7) Cleans up FFmpeg’s internal two-pass log files.

Requirements:
 - FFmpeg ≥ 7.x (with libsvtav1 compiled in).
   Verify with:  ffmpeg -encoders | grep libsvtav1
 - ffprobe on your PATH.
 - Python 3.7+.

Usage:
    Place this script in the folder with your videos, then:
        python batch_two_pass_libsvtav1_with_progress.py
"""

import subprocess
import shutil
import time
import json
import os
import sys
from pathlib import Path
from datetime import datetime

# ----------------------------------------------------------------------------
#  CONFIGURATION
# ----------------------------------------------------------------------------

# 1) Executables
FFMPEG_CMD  = "ffmpeg"
FFPROBE_CMD = "ffprobe"

# 2) Two-pass settings → VBR mode (no CBR)
TARGET_BITRATE = "5000k"       # average video bitrate (2 Mbps)
# BUFSIZE and -maxrate are removed for VBR
SVTAV1_PARAMS  = "preset=6:tile-rows=2:tile-columns=2:scd=1:aq-mode=1:tune=0"

# 3) Audio settings
AUDIO_CODEC   = "libopus"
AUDIO_BITRATE = "100k"         # 100 kbps Opus

# 4) Video file extensions (case-insensitive)
VIDEO_EXTENSIONS = [
    ".avi", ".mpg", ".mp4", ".flv", ".3gp",
    ".mkv", ".wmv", ".mov", ".mts", ".vob", ".webm"
]

# 5) Output folders
DIR_OVER   = Path("over")
DIR_OUTPUT = Path("output")

# ----------------------------------------------------------------------------
#  HELPERS: human_readable_size, ffprobe→summary, print_comparison
# ----------------------------------------------------------------------------

def human_readable_size(num_bytes: int) -> str:
    """Convert bytes → megabytes (2 decimal places)."""
    mb = num_bytes / (1024 * 1024)
    return f"{mb:.2f} MB"

def run_ffprobe(path: Path) -> dict:
    """
    Run ffprobe on `path` and return a JSON‐parsed dict of 'format' and 'streams'.
    Returns {} on failure.
    """
    cmd = [
        FFMPEG_CMD.replace("ffmpeg", "ffprobe"),
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        str(path)
    ]
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        return json.loads(raw)
    except subprocess.CalledProcessError:
        return {}

def extract_summary(probe_info: dict) -> dict:
    """
    Given ffprobe JSON, extract:
      - duration (sec, float)
      - bit_rate (bits/sec, int)
      - file_size (bytes, int)
      - video_codec (str), width (int), height (int)
      - audio_codec (str)
    Returns a dict; missing fields stay None.
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

    fmt = probe_info.get("format", {})
    if fmt:
        dur = fmt.get("duration", None)
        summary["duration"] = float(dur) if dur is not None else None

        br = fmt.get("bit_rate", None)
        summary["bit_rate"] = int(br) if br is not None else None

        sz = fmt.get("size", None)
        summary["file_size"] = int(sz) if sz is not None else None

    streams = probe_info.get("streams", [])
    for s in streams:
        if s.get("codec_type") == "video" and summary["video_codec"] is None:
            summary["video_codec"] = s.get("codec_name")
            summary["width"]      = s.get("width")
            summary["height"]     = s.get("height")
        elif s.get("codec_type") == "audio" and summary["audio_codec"] is None:
            summary["audio_codec"] = s.get("codec_name")
        if summary["video_codec"] and summary["audio_codec"]:
            break

    return summary

def format_duration(seconds: float) -> str:
    """Convert seconds → 'HH:MM:SS', or 'N/A' if None."""
    if seconds is None:
        return "N/A"
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"

def format_bitrate(bits_per_sec: int) -> str:
    """Convert bits/sec → 'X.XX Mbps', or 'N/A' if None."""
    if bits_per_sec is None:
        return "N/A"
    mbps = bits_per_sec / 1_000_000
    return f"{mbps:.2f} Mbps"

def print_comparison(orig: Path, comp: Path):
    """
    Use ffprobe on both `orig` and `comp` to print a side-by-side table:
      • Duration
      • Bitrate
      • File size
      • Video codec & resolution
      • Audio codec
    """
    print("  ↳ Running ffprobe comparison…")
    orig_info = run_ffprobe(orig)
    comp_info = run_ffprobe(comp)

    orig_sum = extract_summary(orig_info)
    comp_sum = extract_summary(comp_info)

    rows = []
    rows.append([
        "Duration",
        format_duration(orig_sum["duration"]),
        format_duration(comp_sum["duration"])
    ])
    rows.append([
        "Bitrate",
        format_bitrate(orig_sum["bit_rate"]),
        format_bitrate(comp_sum["bit_rate"])
    ])
    rows.append([
        "File size",
        human_readable_size(orig_sum["file_size"]) if orig_sum["file_size"] else "N/A",
        human_readable_size(comp_sum["file_size"]) if comp_sum["file_size"] else "N/A"
    ])
    def vf(codec, w, h):
        if codec is None:
            return "N/A"
        if w and h:
            return f"{codec} ({w}×{h})"
        return codec

    rows.append([
        "Video codec & res",
        vf(orig_sum["video_codec"], orig_sum["width"], orig_sum["height"]),
        vf(comp_sum["video_codec"], comp_sum["width"], comp_sum["height"])
    ])
    rows.append([
        "Audio codec",
        orig_sum["audio_codec"] or "N/A",
        comp_sum["audio_codec"] or "N/A"
    ])

    col0 = max(len(r[0]) for r in rows) + 2
    col1 = max(len(r[1]) for r in rows) + 2
    col2 = max(len(r[2]) for r in rows) + 2

    print()
    print(f"    {'Property'.ljust(col0)}{'Original'.ljust(col1)}{'Compressed'.ljust(col2)}")
    print("    " + "-" * (col0 + col1 + col2))
    for r in rows:
        print(f"    {r[0].ljust(col0)}{r[1].ljust(col1)}{r[2].ljust(col2)}")
    print()

# ----------------------------------------------------------------------------
#  MAIN TWO-PASS FUNCTION (with real-time FFmpeg progress)
# ----------------------------------------------------------------------------

def process_video(input_path: Path):
    """
    1) Build a unique passlog base using a timestamp.
    2) Pass 1: FFmpeg (analysis-only, no audio, VBR mode) → stats written to "<base>-0.log".
    3) Pass 2: FFmpeg (encode AV1 + Opus, VBR, using same base) → temp.mp4.
    4) Print real-time FFmpeg progress for both passes (frame, fps, time, size).
    5) ffprobe comparison (original vs. compressed).
    6) Move original → over/, compressed → output/.
    7) Remove FFmpeg’s internal two-pass log files ("<base>-0.log", "<base>-0.log.mbtree").
    """
    print("\n" + "_" * 100)
    print(f"Processing: {input_path.name}")

    # 1) Record original file size
    try:
        orig_size = input_path.stat().st_size
    except FileNotFoundError:
        print(f"  [Error] File not found: {input_path}")
        return

    # 2) Unique passlog base (stem + timestamp)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    passlog_base = f"{input_path.stem}_{ts}_svp"

    pass1_log = Path(f"{input_path.stem}_{ts}_pass1.log")
    pass2_log = Path(f"{input_path.stem}_{ts}_pass2.log")
    temp_filename = f"{input_path.stem}_{ts}.mp4"
    temp_path = Path(temp_filename)

    # ------------------------------------------------------------------------
    # PASS 1: analysis‐only, VBR (no audio → output to null)
    # ------------------------------------------------------------------------
    cmd_pass1 = [
        FFMPEG_CMD,
        "-hide_banner",
        "-loglevel", "info",
        "-y",
        "-i", str(input_path),
        "-c:v", "libsvtav1",
        "-b:v", TARGET_BITRATE,
        "-rc", "2",                         # VBR mode
        "-svtav1-params", SVTAV1_PARAMS,
        "-pass", "1",
        "-passlogfile", passlog_base,
        "-an",                              # disable audio on Pass 1
        "-f", "null", os.devnull
    ]

    print(f"  → Pass 1 (analysis) @ {TARGET_BITRATE} VBR → see progress below, logs → '{pass1_log.name}'")
    start1 = time.perf_counter()
    with pass1_log.open("w", encoding="utf-8", errors="ignore") as lf:
        # Launch FFmpeg as a subprocess, capturing stdout/stderr
        proc = subprocess.Popen(
            cmd_pass1,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=1
        )
        # Read line by line and echo to both console & log file
        for line in proc.stdout:
            # Print exactly as FFmpeg prints (progress, frame=…, etc.)
            sys.stdout.write(line)
            lf.write(line)
        proc.wait()
    elapsed1 = time.perf_counter() - start1

    if proc.returncode != 0:
        print(f"  [Error] Pass 1 exited with code {proc.returncode}. Check '{pass1_log.name}'.")
        # Print first few lines for quick debugging:
        with pass1_log.open("r", encoding="utf-8", errors="ignore") as lf:
            for i, line in enumerate(lf):
                if i >= 5:
                    break
                print("    " + line.rstrip())
        return

    print(f"  • Pass 1 completed in {elapsed1:.1f} sec → stats in '{passlog_base}-0.log'")

    # ------------------------------------------------------------------------
    # PASS 2: encode AV1 + Opus (VBR, using passlog_base)
    # ------------------------------------------------------------------------
    cmd_pass2 = [
        FFMPEG_CMD,
        "-hide_banner",
        "-loglevel", "info",
        "-y",
        "-i", str(input_path),
        "-c:v", "libsvtav1",
        "-b:v", TARGET_BITRATE,
        "-rc", "2",                         # VBR mode
        "-svtav1-params", SVTAV1_PARAMS,
        "-pass", "2",
        "-passlogfile", passlog_base,
        "-c:a", AUDIO_CODEC,
        "-b:a", AUDIO_BITRATE,
        str(temp_path)
    ]

    print(f"  → Pass 2 (encode AV1 + Opus) → '{temp_filename}' (progress below)")
    start2 = time.perf_counter()
    with pass2_log.open("w", encoding="utf-8", errors="ignore") as lf:
        proc = subprocess.Popen(
            cmd_pass2,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=1
        )
        for line in proc.stdout:
            sys.stdout.write(line)
            lf.write(line)
        proc.wait()
    elapsed2 = time.perf_counter() - start2

    if proc.returncode != 0:
        print(f"  [Error] Pass 2 exited with code {proc.returncode}. Check '{pass2_log.name}'.")
        with pass2_log.open("r", encoding="utf-8", errors="ignore") as lf:
            for i, line in enumerate(lf):
                if i >= 5:
                    break
                print("    " + line.rstrip())
        return

    print(f"  • Pass 2 completed in {elapsed2:.1f} sec → compressed size: {human_readable_size(temp_path.stat().st_size)}")

    # ------------------------------------------------------------------------
    # FFPROBE comparison (original vs. compressed)
    # ------------------------------------------------------------------------
    print(f"  • Original size  : {human_readable_size(orig_size)}")
    print(f"  • Compressed size: {human_readable_size(temp_path.stat().st_size)}")
    print_comparison(input_path, temp_path)

    # ------------------------------------------------------------------------
    # CLEAN UP libsvtav1 two-pass internal logs:
    #   "<passlog_base>-0.log" and "<passlog_base>-0.log.mbtree"
    # ------------------------------------------------------------------------
    for suffix in ["-0.log", "-0.log.mbtree"]:
        internal_log = Path(f"{passlog_base}{suffix}")
        if internal_log.exists():
            internal_log.unlink()

    # (Optional) delete human logs automatically:
    # pass1_log.unlink()
    # pass2_log.unlink()

    # ------------------------------------------------------------------------
    # MOVE original → over/   and   compressed → output/
    # ------------------------------------------------------------------------
    target_over = DIR_OVER / input_path.name
    if target_over.exists():
        target_over.unlink()
    shutil.move(str(input_path), str(target_over))
    print(f"  ✔ Moved original → '{target_over}'")

    final_name = f"{input_path.stem}.mp4"
    target_out = DIR_OUTPUT / final_name
    if target_out.exists():
        target_out.unlink()
    shutil.move(str(temp_path), str(target_out))
    print(f"  ✔ Moved compressed → '{target_out}'")

# ----------------------------------------------------------------------------
#  MAIN ENTRY POINT
# ----------------------------------------------------------------------------

def main():
    # Ensure output directories exist
    DIR_OVER.mkdir(exist_ok=True)
    DIR_OUTPUT.mkdir(exist_ok=True)

    cwd = Path.cwd()
    video_files = []

    # Collect any file matching VIDEO_EXTENSIONS (case-insensitive)
    for ext in VIDEO_EXTENSIONS:
        video_files.extend(cwd.glob(f"*{ext}"))
        video_files.extend(cwd.glob(f"*{ext.upper()}"))

    if not video_files:
        print("No video files found with those extensions.")
        return

    video_files = sorted(video_files)
    for idx, vid in enumerate(video_files, start=1):
        print(f"\n>>> ({idx}/{len(video_files)})")
        process_video(vid)

    print("\n" + "_" * 60)
    print("Batch two-pass libsvtav1 job completed at:", datetime.now().strftime("%d/%m/%Y %H:%M:%S"))

if __name__ == "__main__":
    main()
