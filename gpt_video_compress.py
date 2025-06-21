#!/usr/bin/env python3
"""
batch_compress_av1.py  (v2.0.0)
--------------------------------
Traverse the current directory for video files (by extension),
compress each to AV1 (libsvtav1) + Opus audio, and move:
    • original -> ./over/ 
    • compressed -> ./output/

Usage: 
    Just run “python batch_compress_av1.py” in a folder containing videos.
    It will create “over/” and “output/” subfolders if they don't exist.
"""

import subprocess
import shutil
import time
from pathlib import Path
from datetime import datetime

# ------------------------------------------------------------------------
#  CONFIGURATION
# ------------------------------------------------------------------------

# Path to ffmpeg executable; we'll append arguments via a list.
FFMPEG_CMD = "ffmpeg"

# Video‐encoding options:
#  - libsvtav1 (AV1) with 8 threads, CRF=22, GOP size=240, overlays & scene‐change detection enabled,
#    10‐bit pixel format (yuv420p10le). Audio: libopus @ 100 kbps.
VIDEO_OPTIONS = [
    "-c:v", "libsvtav1",
    "-threads", "8",
    "-crf", "22",
    "-g", "240",
    "-svtav1-params", "tune=0:enable-overlays=1:scd=1",
    "-pix_fmt", "yuv420p10le",
    "-c:a", "libopus",
    "-b:a", "100k",
]

# Metadata to inject
METADATA_OPTIONS = [
    "-metadata", "comment=Encoded by Pradeep"
]

# List of file extensions to consider (case‐insensitive)
VIDEO_EXTENSIONS = [
    ".avi", ".mpg", ".mp4", ".flv", ".3gp", 
    ".mkv", ".wmv", ".mov", ".mts", ".vob", ".webm"
]

# Destination folders (will be created if not exist)
DIR_OVER = Path("over")
DIR_OUTPUT = Path("output")

# ------------------------------------------------------------------------
#  HELPER FUNCTIONS
# ------------------------------------------------------------------------

def human_readable_size(bytes_size: int) -> str:
    """
    Convert a size in bytes to a string in megabytes (rounded to 2 decimals).
    """
    mb = bytes_size / (1024 * 1024)
    return f"{mb:.2f} MB"


def process_video(input_path: Path):
    """
    Compresses a single video file (input_path) to AV1/Opus in a temporary file,
    then on success:
        • moves original -> over/
        • renames temp -> base.mp4 -> output/
    Prints timing and size info.
    """
    print("\n" + "_" * 100)
    print(f"Processing: {input_path.name}")

    # Gather original file size
    try:
        orig_size_bytes = input_path.stat().st_size
    except FileNotFoundError:
        print(f"  [Error] File not found: {input_path}")
        return

    # Build a unique temp output filename: e.g., "<stem>_<timestamp>.mp4"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    temp_filename = f"{input_path.stem}_{timestamp}.mp4"
    temp_path = Path(temp_filename)

    # Build an FFmpeg log file name so we can inspect errors if any
    log_filename = f"{input_path.stem}_{timestamp}.log"
    log_path = Path(log_filename)

    # Assemble ffmpeg command as a list (vs. a single shell string)
    cmd = [
        FFMPEG_CMD,
        "-hide_banner",
        "-loglevel", "info",
        "-report",                 # generate a report; by default goes to "ffmpeg-*.log"
        "-y",                      # overwrite output without asking
        "-i", str(input_path),     # input file
        *VIDEO_OPTIONS,            # video & audio encoding opts
        *METADATA_OPTIONS,         # metadata
        str(temp_path)             # output path
    ]

    # Launch FFmpeg, capturing stderr to our custom log_path
    with log_path.open("wb") as lf:
        start = time.perf_counter()
        process = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT)
        end = time.perf_counter()

    elapsed = end - start
    exit_code = process.returncode

    # Print timing
    print(f"  → Time taken: {elapsed:.1f} sec")

    # If FFmpeg failed, show the first few lines of the log and skip further steps
    if exit_code != 0:
        print(f"  [Failure] FFmpeg exited with code {exit_code}. Check log: {log_path}")
        # Optionally: print first 5 lines of the log to console
        with log_path.open("r", errors="ignore") as lf:
            for i, line in enumerate(lf):
                if i >= 5:
                    break
                print(f"    {line.rstrip()}")
        return

    # Gather compressed size
    try:
        comp_size_bytes = temp_path.stat().st_size
    except FileNotFoundError:
        print(f"  [Error] Expected output not found: {temp_path}")
        return

    # Print sizes (original vs. compressed)
    print(f"  • Original size  : {human_readable_size(orig_size_bytes)}")
    print(f"  • Compressed size: {human_readable_size(comp_size_bytes)}")

    # Move original to “over/”
    target_over = DIR_OVER / input_path.name
    if target_over.exists():
        target_over.unlink()
    shutil.move(str(input_path), str(target_over))

    # Move compressed to “output/” under its final name: "<stem>.mp4"
    final_name = f"{input_path.stem}.mp4"
    target_out = DIR_OUTPUT / final_name
    if target_out.exists():
        target_out.unlink()
    shutil.move(str(temp_path), str(target_out))

    print(f"  ✔ Moved original → {target_over}")
    print(f"  ✔ Compressed → {target_out}")
    return


# ------------------------------------------------------------------------
#  MAIN SCRIPT
# ------------------------------------------------------------------------

def main():
    # Create directories (if they don’t exist)
    DIR_OVER.mkdir(exist_ok=True)
    DIR_OUTPUT.mkdir(exist_ok=True)

    # Collect all files in cwd matching our VIDEO_EXTENSIONS
    cwd = Path.cwd()
    video_files = []
    for ext in VIDEO_EXTENSIONS:
        video_files.extend(cwd.glob(f"*{ext}"))
        video_files.extend(cwd.glob(f"*{ext.upper()}"))  # also catch uppercase extensions

    if not video_files:
        print("No video files found with the specified extensions.")
        return

    # Sort them alphabetically (optional)
    video_files = sorted(video_files)

    # Process each file
    for vid in video_files:
        process_video(vid)

    # At the end, print a summary timestamp
    print("\n" + "_" * 60)
    print("All done. Completed at:", datetime.now().strftime("%d/%m/%Y %H:%M:%S"))


if __name__ == "__main__":
    main()
