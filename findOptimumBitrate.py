#!/usr/bin/env python
 """Utilities for finding the optimum bitrate of videos with FFmpeg.
 
 
 Run ``python findOptimumBitrate.py --help`` for a full list of options.
 """
 
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from os import PathLike
from typing import Any, Iterable, Mapping, MutableMapping, Sequence, TypeAlias

Pathish: TypeAlias = str | PathLike[str] | Path

__all__ = [
    "AnalysisConfig",
    "AnalysisResult",
    "Pathish",
    "VideoStream",
    "VideoProbe",
    "analyse_path",
    "analyse_paths",
    "bitrate_from_bits_per_pixel",
    "bits_per_pixel",
    "format_bitrate",
    "parse_arguments",
    "parse_ffprobe_output",
    "parse_fraction",
    "parse_video_stream",
    "recommend_bitrate",
    "request",
    "run_ffprobe",
]

__author__ = "Pradeep Antapnal"
VERSION = "1.1.0"


def request(command: Sequence[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    """Execute ``command`` and return the completed process.

    The tests interact with the script by monkeypatching :func:`request`, so the
    implementation intentionally lives in this module instead of depending on
    ``subprocess.run`` directly.  The helper mirrors ``subprocess.run`` but
    always captures text output which keeps downstream parsing straightforward.
    """

    return subprocess.run(  # type: ignore[return-value]
        command,
        check=check,
        text=True,
        capture_output=True,
    )


@dataclass(slots=True)
class VideoStream:
    """Relevant details for a single ffprobe video stream."""

    width: int
    height: int
    codec: str | None
    fps: float | None
    bitrate: int | None


@dataclass(slots=True)
class VideoProbe:
    """Aggregated metadata returned by :func:`ffprobe`."""

    path: Path
    duration: float | None
    size_bytes: int | None
    format_bitrate: int | None
    video: VideoStream | None

    def average_bitrate(self) -> float | None:
        """Return the average bitrate for the probed file when possible."""

        if self.format_bitrate is not None:
            return float(self.format_bitrate)
        if self.size_bytes is None or self.duration in (None, 0):
            return None
        return (self.size_bytes * 8) / self.duration


def parse_fraction(value: str | None) -> float | None:
    """Convert an ffprobe rational value (``"30000/1001"``) to ``float``."""

    if not value:
        return None
    if value.isdigit():
        return float(value)
    if "/" not in value:
        try:
            return float(value)
        except ValueError:
            return None
    numerator, denominator = value.split("/", 1)
    try:
        num = float(numerator)
        den = float(denominator)
    except ValueError:
        return None
    if den == 0:
        return None
    return num / den


def _safe_int(value: Any) -> int | None:
    """Attempt to coerce *value* to :class:`int`.

    ``ffprobe`` occasionally reports ``"N/A"`` or other placeholders, so the
    helper keeps the parsing logic compact and predictable.
    """

    if value in (None, "N/A", ""):  # common ffprobe placeholders
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_video_stream(streams: Iterable[Mapping[str, Any]]) -> VideoStream | None:
    """Extract the first video stream from *streams* if present."""

    for stream in streams:
        if stream.get("codec_type") != "video":
            continue
        width = _safe_int(stream.get("width"))
        height = _safe_int(stream.get("height"))
        if width is None or height is None:
            continue
        fps = parse_fraction(stream.get("avg_frame_rate"))
        bitrate = _safe_int(stream.get("bit_rate"))
        return VideoStream(
            width=width,
            height=height,
            codec=stream.get("codec_name"),
            fps=fps,
            bitrate=bitrate,
        )
    return None


def parse_ffprobe_output(path: Path, payload: MutableMapping[str, Any]) -> VideoProbe:
    """Convert a JSON dictionary produced by ``ffprobe`` to :class:`VideoProbe`."""

    format_section = payload.get("format")
    duration: float | None = None
    size_bytes: int | None = None
    format_bitrate: int | None = None

    if isinstance(format_section, Mapping):
        if format_section.get("duration") not in (None, "N/A", ""):
            try:
                duration = float(format_section["duration"])
            except (TypeError, ValueError):
                duration = None
        size_bytes = _safe_int(format_section.get("size"))
        format_bitrate = _safe_int(format_section.get("bit_rate"))

    streams = payload.get("streams")
    video_stream: VideoStream | None = None
    if isinstance(streams, Iterable):
        video_stream = parse_video_stream(streams)  # type: ignore[arg-type]

    return VideoProbe(
        path=path,
        duration=duration,
        size_bytes=size_bytes,
        format_bitrate=format_bitrate,
        video=video_stream,
    )


def run_ffprobe(path: Pathish, ffprobe_cmd: str = "ffprobe") -> VideoProbe:
    """Execute ffprobe and return the parsed :class:`VideoProbe` information."""

    command = [
        ffprobe_cmd,
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        str(path),
    ]
    result = request(command)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ffprobe failed")
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:  # pragma: no cover - defensive
        raise RuntimeError("Invalid ffprobe output") from exc
    if not isinstance(payload, MutableMapping):
        raise RuntimeError("Unexpected ffprobe payload")
    return parse_ffprobe_output(Path(path), payload)


def bitrate_from_bits_per_pixel(
    width: int,
    height: int,
    fps: float,
    bits_per_pixel: float,
) -> int:
    """Compute bitrate in bits per second from a bits-per-pixel target."""

    if width <= 0 or height <= 0:
        raise ValueError("Video dimensions must be positive")
    if fps <= 0:
        raise ValueError("Frame rate must be positive")
    if bits_per_pixel <= 0:
        raise ValueError("bits_per_pixel must be positive")
    return math.ceil(width * height * fps * bits_per_pixel)


def bits_per_pixel(bitrate: float, width: int, height: int, fps: float) -> float:
    """Inverse of :func:`bitrate_from_bits_per_pixel`."""

    if width <= 0 or height <= 0:
        raise ValueError("Video dimensions must be positive")
    if fps <= 0:
        raise ValueError("Frame rate must be positive")
    if bitrate <= 0:
        raise ValueError("Bitrate must be positive")
    return bitrate / (width * height * fps)


def recommend_bitrate(
    probe: VideoProbe,
    *,
    target_bpp: float = 0.085,
    fallback_fps: float = 30.0,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    """Return a bitrate recommendation in bits per second.

    The function favours information from the video stream because it is the
    most reliable source for resolution and frame-rate.  When this data is not
    available, the format section is used as a fallback.
    """

    stream = probe.video
    if stream is None:
        avg = probe.average_bitrate()
        if avg is None:
            raise ValueError("Insufficient information to determine bitrate")
        candidate = int(avg)
    else:
        fps = stream.fps or fallback_fps
        candidate = bitrate_from_bits_per_pixel(
            stream.width,
            stream.height,
            fps,
            target_bpp,
        )

    if minimum is not None:
        candidate = max(candidate, minimum)
    if maximum is not None:
        candidate = min(candidate, maximum)
    return candidate


def format_bitrate(bitrate: int) -> str:
    """Return a human-friendly representation for *bitrate*."""

    if bitrate < 1000:
        return f"{bitrate} bps"
    if bitrate < 1_000_000:
        return f"{bitrate / 1000:.2f} kbps"
    return f"{bitrate / 1_000_000:.2f} Mbps"


@dataclass(slots=True)
class AnalysisConfig:
    """Configuration values shared between the CLI and programmatic API."""

    target_bpp: float = 0.085
    fallback_fps: float = 30.0
    minimum: int | None = None
    maximum: int | None = None
    ffprobe: str = field(default_factory=lambda: os.environ.get("FFPROBE", "ffprobe"))


@dataclass(slots=True)
class AnalysisResult:
    """Container for the result of :func:`analyse_paths`."""

    probe: VideoProbe
    recommendation: int | None
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        """Represent the result as a JSON-serialisable dictionary."""

        data: dict[str, Any] = {
            "path": str(self.probe.path),
            "duration": self.probe.duration,
            "size_bytes": self.probe.size_bytes,
            "format_bitrate": self.probe.format_bitrate,
            "video": {
                "width": self.probe.video.width if self.probe.video else None,
                "height": self.probe.video.height if self.probe.video else None,
                "codec": self.probe.video.codec if self.probe.video else None,
                "fps": self.probe.video.fps if self.probe.video else None,
                "bitrate": self.probe.video.bitrate if self.probe.video else None,
            },
            "recommendation": self.recommendation,
        }
        if self.error is not None:
            data["error"] = self.error
        return data


def analyse_paths(
    paths: Iterable[Pathish],
    config: AnalysisConfig | None = None,
) -> list[AnalysisResult]:
    """Run ``ffprobe`` on *paths* and build a structured report."""

    if config is None:
        config = AnalysisConfig()

    resolved_paths = [Path(p) for p in paths]
    results: list[AnalysisResult] = []
    for path in resolved_paths:
        probe = run_ffprobe(path, ffprobe_cmd=config.ffprobe)
        try:
            recommendation = recommend_bitrate(
                probe,
                target_bpp=config.target_bpp,
                fallback_fps=config.fallback_fps,
                minimum=config.minimum,
                maximum=config.maximum,
            )
        except ValueError as exc:
            results.append(AnalysisResult(probe=probe, recommendation=None, error=str(exc)))
        else:
            results.append(AnalysisResult(probe=probe, recommendation=recommendation, error=None))
    return results


def analyse_path(
    path: Pathish,
    config: AnalysisConfig | None = None,
) -> AnalysisResult:
    """Convenience wrapper returning a single :class:`AnalysisResult`."""

    return analyse_paths([path], config=config)[0]


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Build and parse the command line arguments."""

    defaults = AnalysisConfig()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="Video files to analyse")
    parser.add_argument(
        "--ffprobe",
        default=defaults.ffprobe,
        help="ffprobe executable to invoke",
    )
    parser.add_argument(
        "--target-bpp",
        type=float,
        default=defaults.target_bpp,
        help="Desired bits per pixel (default: %(default)s)",
    )
    parser.add_argument(
        "--fallback-fps",
        type=float,
        default=defaults.fallback_fps,
        help="Fallback FPS when ffprobe does not report a frame rate",
    )
    parser.add_argument(
        "--minimum",
        type=int,
        default=None,
        help="Clamp recommendations to be at least this bitrate (bps)",
    )
    parser.add_argument(
        "--maximum",
        type=int,
        default=None,
        help="Clamp recommendations to be at most this bitrate (bps)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results in JSON format",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv)
    config = AnalysisConfig(
        target_bpp=args.target_bpp,
        fallback_fps=args.fallback_fps,
        minimum=args.minimum,
        maximum=args.maximum,
        ffprobe=args.ffprobe,
    )
    report = analyse_paths(args.paths, config=config)

    if args.json:
        json.dump([item.to_dict() for item in report], sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    for item in report:
        data = item.to_dict()
        print(data["path"])
        video = data["video"]
        if data.get("duration") is not None:
            print(f"  Duration: {data['duration']:.2f} s")
        if video.get("width") and video.get("height"):
            print(f"  Resolution: {video['width']}x{video['height']}")
        if video.get("fps"):
            print(f"  Frame rate: {video['fps']:.2f} fps")
        if item.recommendation is not None:
            formatted = format_bitrate(int(item.recommendation))
            print(f"  Recommended bitrate: {formatted}")
        if item.error is not None:
            print(f"  Error: {item.error}")
        print()
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    raise SystemExit(main())
