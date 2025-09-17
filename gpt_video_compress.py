#!/usr/bin/env python3
"""Utilities for compressing batches of videos with FFmpeg.

This module started life as a small script that traversed the current
directory, re-encoded every supported video using ``libsvtav1`` and Opus,
and moved the original and compressed copies to ``./over`` and ``./output``.

The original behaviour is still the default, but the script has been reworked
to offer a friendlier command line experience and more customisation:

* Compress files from multiple directories (optionally recursively).
* Skip files that already have a compressed counterpart.
* Keep FFmpeg logs for later inspection or discard them automatically.
* Perform dry runs to preview the work that would be carried out.

Run ``python gpt_video_compress.py --help`` for a full list of options.
"""

from __future__ import annotations

import argparse
import logging
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Sequence

LOG_FORMAT = "%(levelname)s: %(message)s"
DEFAULT_VIDEO_EXTENSIONS: tuple[str, ...] = (
    ".avi",
    ".mpg",
    ".mp4",
    ".flv",
    ".3gp",
    ".mkv",
    ".wmv",
    ".mov",
    ".mts",
    ".vob",
    ".webm",
)


@dataclass(slots=True)
class CompressionConfig:
    """Container for user-configurable settings."""

    ffmpeg_cmd: str = "ffmpeg"
    threads: int = 8
    crf: int = 22
    gop: int = 240
    svt_params: str = "tune=0:enable-overlays=1:scd=1"
    pix_fmt: str = "yuv420p10le"
    audio_bitrate: str = "100k"
    metadata_comment: str = "Encoded by Pradeep"
    video_extensions: Sequence[str] = field(default_factory=lambda: DEFAULT_VIDEO_EXTENSIONS)
    output_dir: Path = Path("output")
    originals_dir: Path = Path("over")
    log_dir: Path = Path("logs")
    keep_logs: bool = False
    recursive: bool = False
    dry_run: bool = False
    skip_existing: bool = False
    move_originals: bool = True

    def normalised_extensions(self) -> List[str]:
        """Return file extensions normalised to lower-case."""

        return [ext.lower() for ext in self.video_extensions]

    def video_options(self) -> List[str]:
        """Build FFmpeg arguments for video encoding."""

        return [
            "-c:v",
            "libsvtav1",
            "-threads",
            str(self.threads),
            "-crf",
            str(self.crf),
            "-g",
            str(self.gop),
            "-svtav1-params",
            self.svt_params,
            "-pix_fmt",
            self.pix_fmt,
            "-c:a",
            "libopus",
            "-b:a",
            self.audio_bitrate,
        ]

    def metadata_options(self) -> List[str]:
        """Return metadata arguments for FFmpeg."""

        return ["-metadata", f"comment={self.metadata_comment}"]


@dataclass(slots=True)
class CompressionStats:
    """Simple aggregation of script results."""

    processed: int = 0
    skipped: int = 0
    failures: int = 0
    bytes_before: int = 0
    bytes_after: int = 0

    def record_processed(self, original: int, compressed: int) -> None:
        self.processed += 1
        self.bytes_before += original
        self.bytes_after += compressed

    def record_skipped(self) -> None:
        self.skipped += 1

    def record_failure(self) -> None:
        self.failures += 1


def human_readable_size(bytes_size: int) -> str:
    """Convert ``bytes_size`` to a readable string in megabytes."""

    mb = bytes_size / (1024 * 1024)
    return f"{mb:.2f} MB"


def build_ffmpeg_command(
    input_path: Path,
    output_path: Path,
    config: CompressionConfig,
) -> List[str]:
    """Construct the FFmpeg command for a single video."""

    return [
        config.ffmpeg_cmd,
        "-hide_banner",
        "-loglevel",
        "info",
        "-y",
        "-i",
        str(input_path),
        *config.video_options(),
        *config.metadata_options(),
        str(output_path),
    ]


def discover_video_files(paths: Iterable[Path], config: CompressionConfig) -> List[Path]:
    """Collect all video files from *paths* according to *config*."""

    exts = set(config.normalised_extensions())
    discovered: List[Path] = []
    seen: set[Path] = set()
    for base in paths:
        if not base.exists():
            logging.warning("Skipping missing path: %s", base)
            continue

        if base.is_file():
            resolved = base.resolve()
            if resolved.suffix.lower() in exts and resolved not in seen:
                discovered.append(resolved)
                seen.add(resolved)
            continue

        iterator = base.rglob("*") if config.recursive else base.glob("*")
        for candidate in iterator:
            if candidate.is_dir():
                continue
            resolved = candidate.resolve()
            if resolved.suffix.lower() in exts and resolved not in seen:
                discovered.append(resolved)
                seen.add(resolved)

    discovered.sort()
    return discovered


def process_video(input_path: Path, config: CompressionConfig, stats: CompressionStats) -> None:
    """Compress a single video file following ``config`` and update ``stats``."""

    logging.info("Processing %s", input_path)

    try:
        orig_size_bytes = input_path.stat().st_size
    except FileNotFoundError:
        logging.error("File not found: %s", input_path)
        stats.record_failure()
        return

    config.output_dir.mkdir(exist_ok=True, parents=True)
    if config.move_originals:
        config.originals_dir.mkdir(exist_ok=True, parents=True)

    final_name = f"{input_path.stem}.mp4"
    target_out = config.output_dir / final_name

    if config.skip_existing and target_out.exists():
        logging.info("Skipping %s (already compressed)", input_path)
        stats.record_skipped()
        return

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    temp_filename = f"{input_path.stem}_{timestamp}.mp4"
    temp_path = (config.output_dir / temp_filename).resolve()
    if temp_path.exists():
        temp_path.unlink()

    log_path = config.log_dir / f"{input_path.stem}_{timestamp}.log"
    if config.keep_logs:
        config.log_dir.mkdir(exist_ok=True, parents=True)

    cmd = build_ffmpeg_command(input_path, temp_path, config)

    if config.dry_run:
        logging.info("Dry-run: would execute %s", " ".join(cmd))
        stats.record_skipped()
        return

    config.log_dir.mkdir(exist_ok=True, parents=True)
    start = time.perf_counter()
    with log_path.open("wb") as logfile:
        process = subprocess.run(cmd, stdout=logfile, stderr=subprocess.STDOUT)
    elapsed = time.perf_counter() - start

    if process.returncode != 0:
        logging.error(
            "FFmpeg failed for %s (exit code %s). See %s",
            input_path,
            process.returncode,
            log_path,
        )
        stats.record_failure()
        if temp_path.exists():
            temp_path.unlink()
        return

    try:
        comp_size_bytes = temp_path.stat().st_size
    except FileNotFoundError:
        logging.error("Expected output not found: %s", temp_path)
        stats.record_failure()
        if temp_path.exists():
            temp_path.unlink()
        return

    logging.info(
        "Time: %.1fs | Original: %s | Compressed: %s",
        elapsed,
        human_readable_size(orig_size_bytes),
        human_readable_size(comp_size_bytes),
    )

    if config.move_originals:
        target_over = config.originals_dir / input_path.name
        if target_over.exists():
            target_over.unlink()
        shutil.move(str(input_path), str(target_over))
        logging.info("Moved original → %s", target_over)

    if target_out.exists():
        target_out.unlink()
    shutil.move(str(temp_path), str(target_out))
    logging.info("Compressed file → %s", target_out)

    if not config.keep_logs and log_path.exists():
        log_path.unlink(missing_ok=True)

    stats.record_processed(orig_size_bytes, comp_size_bytes)


def summarise(stats: CompressionStats) -> None:
    """Print a short summary of the run."""

    if stats.processed == 0 and stats.skipped == 0 and stats.failures == 0:
        logging.info("No matching files were found.")
        return

    logging.info(
        "%s processed | %s skipped | %s failures",
        stats.processed,
        stats.skipped,
        stats.failures,
    )

    if stats.processed:
        saved = stats.bytes_before - stats.bytes_after
        ratio = (stats.bytes_after / stats.bytes_before) * 100 if stats.bytes_before else 0
        logging.info(
            "Space saved: %s (%.1f%% of original size)",
            human_readable_size(saved),
            100 - ratio,
        )


def parse_arguments(argv: Sequence[str]) -> tuple[argparse.Namespace, CompressionConfig]:
    """Parse command line arguments and build a :class:`CompressionConfig`."""

    parser = argparse.ArgumentParser(
        description="Batch compress videos with FFmpeg (libsvtav1 + Opus)"
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=[Path.cwd()],
        help="Paths to scan for videos",
    )
    parser.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg executable to use")
    parser.add_argument(
        "--threads", type=int, default=8, help="Number of encoding threads"
    )
    parser.add_argument(
        "--crf", type=int, default=22, help="Quality target (constant rate factor)"
    )
    parser.add_argument(
        "--gop", type=int, default=240, help="Maximum distance between keyframes"
    )
    parser.add_argument(
        "--audio-bitrate",
        default="100k",
        help="Audio bitrate for Opus (e.g. 96k, 128k)",
    )
    parser.add_argument(
        "--metadata-comment",
        default="Encoded by Pradeep",
        help="Comment metadata to attach",
    )
    parser.add_argument(
        "--extensions",
        nargs="*",
        help="Custom list of file extensions to include",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("output"),
        help="Directory to place compressed files",
    )
    parser.add_argument(
        "--originals-dir",
        type=Path,
        default=Path("over"),
        help="Directory to move original files",
    )
    parser.add_argument(
        "--log-dir",
        type=Path,
        default=Path("logs"),
        help="Directory to store FFmpeg logs",
    )
    parser.add_argument(
        "--keep-logs",
        action="store_true",
        help="Keep FFmpeg log files instead of deleting them",
    )
    parser.add_argument(
        "--recursive", action="store_true", help="Search directories recursively"
    )
    parser.add_argument(
        "--skip-existing",
        action="store_true",
        help="Skip files whose compressed output already exists",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without invoking FFmpeg",
    )
    parser.add_argument(
        "--no-move-originals",
        action="store_true",
        help="Do not move original files to the 'over' directory",
    )

    args = parser.parse_args(argv)

    config = CompressionConfig(
        ffmpeg_cmd=args.ffmpeg,
        threads=args.threads,
        crf=args.crf,
        gop=args.gop,
        audio_bitrate=args.audio_bitrate,
        metadata_comment=args.metadata_comment,
        video_extensions=tuple(args.extensions) if args.extensions else DEFAULT_VIDEO_EXTENSIONS,
        output_dir=args.output_dir,
        originals_dir=args.originals_dir,
        log_dir=args.log_dir,
        keep_logs=args.keep_logs,
        recursive=args.recursive,
        skip_existing=args.skip_existing or args.dry_run,
        dry_run=args.dry_run,
        move_originals=not args.no_move_originals,
    )

    return args, config


def main(argv: Sequence[str] | None = None) -> int:
    args, config = parse_arguments(argv if argv is not None else sys.argv[1:])

    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)

    video_files = discover_video_files(args.paths or [Path.cwd()], config)
    stats = CompressionStats()

    if not video_files:
        logging.info("No video files found with the specified criteria.")
        return 0

    for video in video_files:
        process_video(video, config, stats)

    summarise(stats)
    logging.info("Completed at %s", datetime.now().strftime("%d/%m/%Y %H:%M:%S"))
    return 0 if stats.failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
