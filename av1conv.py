#!/usr/bin/env python3
"""av1conv.py - Advanced AV1 video conversion helper.

This module is a Python port of the original ``av1conv.sh`` shell script and
preserves the overall workflow, configuration semantics and encoding choices of
that project.  The implementation is intentionally verbose and self-documenting
so that it can serve both as a drop-in replacement for the shell utility and as
sample code for automating high quality AV1 transcodes with FFmpeg.

The script focuses on software based SVT-AV1 encoding and attempts to preserve
original video metadata (HDR information, colour primaries, mastering display
metadata etc.), intelligently choose audio and subtitle tracks and keep the
batch processing ergonomics that the Bash version provided.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_COLOR_RESET = "\033[0m"
_COLOR_CODES = {
    "red": "31",
    "green": "32",
    "yellow": "33",
    "blue": "34",
    "magenta": "35",
    "cyan": "36",
    "white": "37",
}


def _colorize(message: str, colour: Optional[str]) -> str:
    if not colour:
        return message
    code = _COLOR_CODES.get(colour)
    if not code:
        return message
    return f"\033[{code}m{message}{_COLOR_RESET}"


class Logger:
    """Simple colour aware logger used throughout the module."""

    def __init__(self, verbose: bool = False) -> None:
        self.verbose = verbose
        self._lock = threading.Lock()

    def info(self, message: str, colour: Optional[str] = None, *, always: bool = False) -> None:
        if not always and not self.verbose:
            return
        with self._lock:
            print(_colorize(message, colour))

    def notice(self, message: str) -> None:
        with self._lock:
            print(_colorize(message, "blue"))

    def success(self, message: str) -> None:
        with self._lock:
            print(_colorize(message, "green"))

    def warning(self, message: str) -> None:
        with self._lock:
            print(_colorize(message, "yellow"))

    def error(self, message: str) -> None:
        with self._lock:
            print(_colorize(message, "red"), file=sys.stderr)


# ---------------------------------------------------------------------------
# Configuration handling
# ---------------------------------------------------------------------------


def _size_to_bytes(value: str) -> int:
    """Convert size strings such as ``1G`` into integer bytes."""

    multipliers = {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3, "t": 1024 ** 4}
    value = value.strip()
    match = re.fullmatch(r"(\d+)([kKmMgGtT]?)", value)
    if not match:
        raise ValueError(f"Invalid size value: {value}")
    number, suffix = match.groups()
    multiplier = multipliers.get(suffix.lower(), 1)
    return int(number) * multiplier


@dataclass
class Config:
    """Runtime configuration options for the converter."""

    directory: Path = Path("/mnt/movies")
    verbose: bool = False
    preset: int = 5
    animation_preset: int = 6
    tv_preset: int = 5
    film_preset: int = 4
    max_parallel_jobs: int = 1
    crf: int = 28
    gop: int = 120
    size_threshold: str = "1G"
    remove_input_file: bool = False
    lazy: bool = False
    allow_larger_files: bool = False
    force: bool = False
    ignore_terms: Tuple[str, ...] = ("CAM", "WORKPRINT", "TELESYNC")
    extra_ignore_terms: Tuple[str, ...] = ()
    force_reencode: bool = False
    resize: bool = False
    resize_target_height: int = 1080
    ffmpeg_threads: int = 6
    detect_grain: bool = False
    detect_grain_test: Optional[Path] = None
    temp_root: Path = Path("/tmp")
    cleanup_on_exit: bool = True
    reencoded_by: str = "geekphreek"
    skip_dolby_vision: bool = False
    stereo_downmix: bool = False
    audio_bitrate_override: Optional[str] = None
    preferred_audio_language: str = "eng"
    preferred_subtitle_language: str = "eng"
    forced_subtitles_only: bool = True
    personal_ffmpeg_path: Optional[Path] = None
    svt_tune: int = 1
    svt_enable_overlays: int = 0
    svt_fast_decode: int = 1
    svt_lookahead: int = 32
    svt_enable_qm: int = 1
    svt_qm_min: int = 0
    svt_qm_max: int = 15
    svt_tile_columns: int = 2
    svt_film_grain: int = 0
    svt_aq_mode: int = 2
    svt_sharpness: int = 0
    crf_animation: int = 29
    crf_film: int = 22
    crf_tv: int = 26
    resize_heuristic: str = "downscale"  # placeholder for documentation

    def as_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)

    @property
    def size_threshold_bytes(self) -> int:
        return _size_to_bytes(self.size_threshold)

    def content_type_crf(self, content_type: str) -> int:
        mapping = {
            "animation": self.crf_animation,
            "film": self.crf_film,
            "tv": self.crf_tv,
        }
        return mapping.get(content_type, self.crf)

    def content_type_preset(self, content_type: str) -> int:
        mapping = {
            "animation": self.animation_preset,
            "film": self.film_preset,
            "tv": self.tv_preset,
        }
        return mapping.get(content_type, self.preset)


_SAMPLE_CONFIG = textwrap.dedent(
    """
    # Sample av1conv configuration file generated by av1conv.py
    # Comment lines begin with '#'.  Values mirror the defaults built into the
    # program and can be overridden individually.
    #
    # Example: override the default CRF and enable verbose logging
    # crf=26
    # verbose=true
    #
    directory=/mnt/movies
    verbose=false
    preset=5
    animation_preset=6
    tv_preset=5
    film_preset=4
    max_parallel_jobs=1
    crf=28
    gop=120
    size_threshold=1G
    remove_input_file=false
    lazy=false
    allow_larger_files=false
    force=false
    force_reencode=false
    resize=false
    resize_target_height=1080
    ffmpeg_threads=6
    detect_grain=false
    temp_root=/tmp
    cleanup_on_exit=true
    reencoded_by=geekphreek
    skip_dolby_vision=false
    stereo_downmix=false
    audio_bitrate_override=
    preferred_audio_language=eng
    preferred_subtitle_language=eng
    forced_subtitles_only=true
    personal_ffmpeg_path=
    svt_tune=1
    svt_enable_overlays=0
    svt_fast_decode=1
    svt_lookahead=32
    svt_enable_qm=1
    svt_qm_min=0
    svt_qm_max=15
    svt_tile_columns=2
    svt_film_grain=0
    svt_aq_mode=2
    svt_sharpness=0
    crf_animation=29
    crf_film=22
    crf_tv=26
    # Additional values may be added in future releases. Unknown keys are
    # ignored with a warning when encountered.
    """
)


def generate_sample_config(path: Path) -> None:
    path.write_text(_SAMPLE_CONFIG, encoding="utf-8")


def _parse_bool(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}


def load_config_file(path: Path, config: Config, logger: Logger) -> None:
    """Load overrides from a simple ``key=value`` configuration file."""

    if not path.exists():
        raise FileNotFoundError(path)

    key_types: Dict[str, Tuple[str, Any]] = {}
    for field_ in dataclasses.fields(config):
        key_types[field_.name] = (field_.type, getattr(config, field_.name))

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            logger.warning(f"Ignoring malformed config line: {raw_line}")
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key not in key_types:
            logger.warning(f"Ignoring unknown configuration key: {key}")
            continue
        if value == "":
            setattr(config, key, None)
            continue
        current = getattr(config, key)
        try:
            if isinstance(current, bool):
                setattr(config, key, _parse_bool(value))
            elif isinstance(current, int):
                setattr(config, key, int(value))
            elif isinstance(current, Path):
                setattr(config, key, Path(value))
            elif isinstance(current, tuple):
                parts = [p.strip() for p in value.split(",") if p.strip()]
                setattr(config, key, tuple(parts))
            else:
                setattr(config, key, value)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning(f"Failed to parse config value for {key}: {exc}")


# ---------------------------------------------------------------------------
# Command line interface
# ---------------------------------------------------------------------------


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="High quality SVT-AV1 batch encoder",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    parser.add_argument("directory", nargs="?", help="Directory to scan for videos")
    parser.add_argument("--generate-config", action="store_true", help="Create a sample configuration file and exit")
    parser.add_argument("--config", type=Path, help="Path to custom configuration file")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose logging")
    parser.add_argument("-f", "--force", action="store_true", help="Force processing even if heuristics want to skip")
    parser.add_argument("-F", "--force-reencode", action="store_true", help="Re-encode files that already use AV1")
    parser.add_argument("-p", "--preset", type=int, help="Override SVT-AV1 preset")
    parser.add_argument("-c", "--crf", type=int, help="Override CRF value")
    parser.add_argument("-J", "--parallel", type=int, dest="max_parallel_jobs", help="Number of parallel encodes")
    parser.add_argument("-g", "--gop", type=int, help="GOP size (key frame interval)")
    parser.add_argument("-s", "--size", dest="size_threshold", help="Minimum file size to process")
    parser.add_argument("-r", "--remove", dest="remove_input_file", action="store_true", help="Remove original file after successful encode")
    parser.add_argument("-R", "--resize-1080p", action="store_true", help="Resize sources above 1080p to 1080p")
    parser.add_argument("--resize-720p", action="store_true", help="Resize sources above 720p to 720p")
    parser.add_argument("--allow-larger", dest="allow_larger_files", action="store_true", help="Keep AV1 encodes even if larger than source")
    parser.add_argument("--temp-dir", type=Path, dest="temp_root", help="Custom temporary directory root")
    parser.add_argument("--keep-temp", dest="cleanup_on_exit", action="store_false", help="Do not delete temporary files (debugging)")
    parser.add_argument("--stereo", dest="stereo_downmix", action="store_true", help="Downmix audio to stereo")
    parser.add_argument("-ab", "--audiobitrate", dest="audio_bitrate_override", help="Explicit audio bitrate (e.g. 192k)")
    parser.add_argument("--detect-grain", action="store_true", help="Enable automatic grain heuristics")
    parser.add_argument("--no-detect-grain", dest="detect_grain", action="store_false", help="Disable automatic grain heuristics")
    parser.add_argument("--detect-grain-test", type=Path, help="Analyse a single file and print the grain verdict")
    parser.add_argument("--skip-dolby-vision", action="store_true", help="Skip Dolby Vision profile 5 titles")
    parser.add_argument("--ignore", action="append", dest="extra_ignore_terms", default=[], help="Additional case-insensitive keywords to skip")
    parser.add_argument("--personal-ffmpeg", type=Path, dest="personal_ffmpeg_path", help="Explicit path to FFmpeg binary")
    parser.add_argument("--preferred-audio-language", dest="preferred_audio_language", help="Preferred audio language (3 letter code)")
    parser.add_argument("--preferred-subtitle-language", dest="preferred_subtitle_language", help="Preferred subtitle language (3 letter code)")
    parser.add_argument("--include-forced-subs", dest="forced_subtitles_only", action="store_false", help="Include all subtitles instead of forced-only")
    parser.add_argument("--generate-report", action="store_true", help="Print JSON summary of the encode session")

    return parser


def apply_args_to_config(args: argparse.Namespace, config: Config) -> None:
    arg_dict = vars(args)
    for key, value in arg_dict.items():
        if value is None:
            continue
        if not hasattr(config, key):
            continue
        setattr(config, key, value)

    if args.resize_1080p:
        config.resize = True
        config.resize_target_height = 1080
    if getattr(args, "resize_720p", False):
        config.resize = True
        config.resize_target_height = 720
    config.extra_ignore_terms = tuple(config.extra_ignore_terms)

    if args.detect_grain_test:
        config.detect_grain_test = args.detect_grain_test

    if config.force_reencode:
        config.force = True


# ---------------------------------------------------------------------------
# FFmpeg discovery and probing
# ---------------------------------------------------------------------------


@dataclass
class FFmpegToolchain:
    ffmpeg: Path
    ffprobe: Path
    has_svt_av1: bool
    supports_libopus: bool
    supports_aac: bool


def _check_encoder(binary: Path, encoder: str) -> bool:
    try:
        out = subprocess.run(
            [str(binary), "-hide_banner", "-encoders"],
            check=True,
            text=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    pattern = re.compile(rf"\b{re.escape(encoder)}\b", re.IGNORECASE)
    return bool(pattern.search(out.stdout))


def find_ffmpeg(config: Config, logger: Logger) -> FFmpegToolchain:
    candidates: List[Path] = []
    if config.personal_ffmpeg_path:
        candidates.append(Path(config.personal_ffmpeg_path))
    candidates.extend(
        Path(p)
        for p in (
            "/usr/lib/jellyfin-ffmpeg/ffmpeg",
            "/opt/ffmpeg/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            os.environ.get("FFMPEG"),
            shutil.which("ffmpeg"),
            "/usr/bin/ffmpeg",
        )
        if p
    )

    logger.info("Looking for FFmpeg installation...", "cyan", always=True)
    for candidate in candidates:
        if not candidate:
            continue
        if not candidate.exists() or not os.access(candidate, os.X_OK):
            logger.info(f"Skipping non executable candidate {candidate}", always=True)
            continue
        try:
            result = subprocess.run([str(candidate), "-version"], capture_output=True, text=True, check=True)
        except (OSError, subprocess.CalledProcessError):
            logger.warning(f"Failed to run FFmpeg candidate {candidate}")
            continue
        logger.success(f"Using FFmpeg at {candidate} ({result.stdout.splitlines()[0]})")
        ffprobe_path = candidate.parent / "ffprobe"
        if not ffprobe_path.exists():
            ffprobe_path = Path(shutil.which("ffprobe") or ffprobe_path)
        if not ffprobe_path or not ffprobe_path.exists():
            raise RuntimeError("Could not locate ffprobe for the chosen FFmpeg")
        has_svt = _check_encoder(candidate, "libsvtav1")
        if not has_svt:
            raise RuntimeError("Selected FFmpeg build does not include libsvtav1 encoder")
        supports_libopus = _check_encoder(candidate, "libopus")
        supports_aac = _check_encoder(candidate, "aac") or _check_encoder(candidate, "libfdk_aac")
        return FFmpegToolchain(candidate, ffprobe_path, has_svt, supports_libopus, supports_aac)

    raise RuntimeError("No suitable FFmpeg installation found")


# ---------------------------------------------------------------------------
# Media analysis
# ---------------------------------------------------------------------------


@dataclass
class StreamInfo:
    index: int
    codec: str
    codec_type: str
    language: Optional[str]
    channels: Optional[int] = None
    tags: Dict[str, Any] = field(default_factory=dict)
    disposition: Dict[str, Any] = field(default_factory=dict)
    bit_rate: Optional[float] = None
    sample_rate: Optional[int] = None
    width: Optional[int] = None
    height: Optional[int] = None
    pix_fmt: Optional[str] = None
    bits_per_raw_sample: Optional[int] = None
    color_transfer: Optional[str] = None
    color_space: Optional[str] = None
    color_primaries: Optional[str] = None
    color_range: Optional[str] = None
    side_data_list: List[Dict[str, Any]] = field(default_factory=list)


@dataclass
class MediaInfo:
    path: Path
    format_tags: Dict[str, Any]
    video: StreamInfo
    audio_streams: List[StreamInfo]
    subtitle_streams: List[StreamInfo]
    duration: float
    size_bytes: int

    @property
    def is_hdr(self) -> bool:
        transfer = (self.video.color_transfer or "").lower()
        if transfer in {"smpte2084", "arib-std-b67", "iec61966-2-4"}:
            return True
        for data in self.video.side_data_list:
            type_name = data.get("side_data_type", "").lower()
            if "mastering display" in type_name or "content light" in type_name:
                return True
        return False

    @property
    def has_dolby_vision(self) -> bool:
        for data in self.video.side_data_list:
            if data.get("side_data_type", "").lower().startswith("dolby vision"):
                return True
        profile = None
        for data in self.video.side_data_list:
            if "dv_profile" in data:
                profile = data.get("dv_profile")
        if profile:
            return True
        # Some Dolby Vision streams expose codec_tag string "dvh1" or "dvhe"
        codec_tag_string = (self.video.tags or {}).get("codec_tag_string", "").lower()
        if codec_tag_string.startswith("dv"):
            return True
        return False


def ffprobe_media(path: Path, toolchain: FFmpegToolchain) -> MediaInfo:
    command = [
        str(toolchain.ffprobe),
        "-hide_banner",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        str(path),
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"ffprobe failed for {path}: {exc.stderr}")
    data = json.loads(result.stdout)
    format_tags = data.get("format", {}).get("tags", {}) or {}
    duration = float(data.get("format", {}).get("duration", 0.0) or 0.0)
    size_bytes = int(data.get("format", {}).get("size", 0) or path.stat().st_size)

    video_streams = [s for s in data.get("streams", []) if s.get("codec_type") == "video"]
    if not video_streams:
        raise RuntimeError(f"No video stream found in {path}")
    video = _build_stream_info(video_streams[0])

    audio_streams = [_build_stream_info(s) for s in data.get("streams", []) if s.get("codec_type") == "audio"]
    subtitle_streams = [_build_stream_info(s) for s in data.get("streams", []) if s.get("codec_type") == "subtitle"]

    return MediaInfo(path=path, format_tags=format_tags, video=video, audio_streams=audio_streams, subtitle_streams=subtitle_streams, duration=duration, size_bytes=size_bytes)


def _build_stream_info(data: Dict[str, Any]) -> StreamInfo:
    tags = data.get("tags", {}) or {}
    disposition = data.get("disposition", {}) or {}
    language = (tags.get("language") or tags.get("LANGUAGE") or "").strip() or None
    bit_rate = None
    if data.get("bit_rate"):
        try:
            bit_rate = float(data["bit_rate"])
        except ValueError:
            pass
    return StreamInfo(
        index=int(data.get("index", 0)),
        codec=data.get("codec_name"),
        codec_type=data.get("codec_type"),
        language=language,
        channels=data.get("channels"),
        tags=tags,
        disposition=disposition,
        bit_rate=bit_rate,
        sample_rate=data.get("sample_rate"),
        width=data.get("width"),
        height=data.get("height"),
        pix_fmt=data.get("pix_fmt"),
        bits_per_raw_sample=_safe_int(data.get("bits_per_raw_sample")),
        color_transfer=data.get("color_transfer"),
        color_space=data.get("color_space"),
        color_primaries=data.get("color_primaries"),
        color_range=data.get("color_range"),
        side_data_list=data.get("side_data_list", []) or [],
    )


def _safe_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Heuristics for content type and grain detection
# ---------------------------------------------------------------------------


def detect_content_type(info: MediaInfo) -> str:
    """Return ``film``, ``tv`` or ``animation`` using light-weight heuristics.

    The shell version relies on a bespoke machine learning model.  The Python
    port keeps the behaviour deterministic and dependency free by observing the
    frame rate, codec tags and titles.  These heuristics aim to mirror the
    typical outcomes of the ML detector: animated content usually carries the
    "Animation" or "Anime" genre tags and high average saturation, while
    episodic television commonly includes `SxxEyy` patterns in file names.
    """

    name = info.path.name.lower()
    title = (info.format_tags.get("title") or "").lower()
    if any(keyword in name for keyword in (".s0", "episode", "season")):
        return "tv"
    if any(keyword in title for keyword in ("episode", "series")):
        return "tv"
    if any(keyword in name for keyword in ("animation", "anime", "cartoon")):
        return "animation"
    if any(keyword in title for keyword in ("animation", "anime")):
        return "animation"
    # Heuristic: very high frame rates are often animation/interlaced
    if info.video and info.video.pix_fmt and "yuv420p" in info.video.pix_fmt and info.video.bits_per_raw_sample == 8:
        return "animation"
    return "film"


def estimate_grain_level(info: MediaInfo) -> int:
    """Return a film grain strength hint between 0 and 50.

    The original script optionally queried a machine learning model.  In this
    port we approximate grain strength by inspecting bitrate density and HDR
    presence: HDR titles generally require no synthetic grain while grainy SDR
    film scans tend to come from high bitrate sources.
    """

    if info.is_hdr:
        return 0
    if not info.duration or not info.size_bytes:
        return 0
    bits_per_second = info.size_bytes * 8 / info.duration
    # Rough heuristics tuned to match the default presets in the shell script
    if bits_per_second > 14_000_000:
        return 20
    if bits_per_second > 10_000_000:
        return 12
    if bits_per_second > 6_000_000:
        return 8
    return 0


# ---------------------------------------------------------------------------
# Stream selection helpers
# ---------------------------------------------------------------------------


def choose_audio_stream(info: MediaInfo, config: Config, toolchain: FFmpegToolchain, logger: Logger) -> StreamInfo:
    if not info.audio_streams:
        raise RuntimeError(f"No audio streams found in {info.path}")
    preferred_lang = config.preferred_audio_language.lower()
    candidates = [s for s in info.audio_streams if (s.language or "").lower() == preferred_lang]
    if not candidates:
        candidates = info.audio_streams
    # Prefer streams already Opus/AAC unless downmix is requested
    def score(stream: StreamInfo) -> Tuple[int, int, int, int, float]:
        default_score = 1 if stream.disposition.get("default") else 0
        forced_penalty = -1 if stream.disposition.get("commentary") else 0
        codec_score = 0
        if stream.codec in {"opus", "libopus"}:
            codec_score = 2
        elif stream.codec in {"aac", "libfdk_aac"}:
            codec_score = 1
        channel_score = -(stream.channels or 2)
        return (default_score, forced_penalty, codec_score, channel_score, -(stream.bit_rate or 0))

    selected = max(candidates, key=score)
    logger.info(f"Selected audio stream {selected.index} ({selected.codec}, {selected.channels}ch)", "cyan", always=True)
    return selected


def choose_subtitle_streams(info: MediaInfo, config: Config, logger: Logger) -> List[StreamInfo]:
    if not info.subtitle_streams:
        return []
    preferred_lang = config.preferred_subtitle_language.lower()
    forced_only = config.forced_subtitles_only

    selected: List[StreamInfo] = []
    for stream in info.subtitle_streams:
        lang = (stream.language or "").lower()
        if preferred_lang and lang != preferred_lang:
            continue
        if forced_only and not stream.disposition.get("forced"):
            continue
        selected.append(stream)

    if not selected and not forced_only:
        selected = [s for s in info.subtitle_streams if (s.language or "").lower() == preferred_lang]

    if not selected:
        logger.info("No subtitle streams matched preferences", "yellow", always=True)
    else:
        logger.info(
            "Including subtitle streams: " + ", ".join(str(s.index) for s in selected),
            "cyan",
            always=True,
        )
    return selected


# ---------------------------------------------------------------------------
# ffmpeg command construction
# ---------------------------------------------------------------------------


@dataclass
class EncodePlan:
    source: Path
    command: List[str]
    temp_dir: Path
    temp_file: Path
    final_destination: Path
    source_size: int


_VIDEO_EXTENSIONS = {
    ".mkv",
    ".mp4",
    ".mov",
    ".avi",
    ".ts",
    ".m2ts",
    ".wmv",
    ".flv",
    ".mpg",
    ".mpeg",
    ".vob",
    ".mxf",
    ".webm",
    ".3gp",
    ".asf",
    ".rm",
    ".rmvb",
}


def should_skip_file(path: Path, config: Config) -> bool:
    if not path.is_file():
        return True
    if path.suffix.lower() not in _VIDEO_EXTENSIONS:
        return True
    if path.name.lower().endswith(".av1.mkv"):
        return True
    if path.stat().st_size < config.size_threshold_bytes and not config.force:
        return True
    name_upper = path.name.upper()
    for keyword in config.ignore_terms + config.extra_ignore_terms:
        if keyword.upper() in name_upper:
            return True
    return False


def build_encode_plan(info: MediaInfo, config: Config, toolchain: FFmpegToolchain, logger: Logger) -> EncodePlan:
    audio_stream = choose_audio_stream(info, config, toolchain, logger)
    subtitle_streams = choose_subtitle_streams(info, config, logger)

    if info.video.codec in {"av1"} and not config.force_reencode:
        raise RuntimeError("Source already encoded with AV1. Use --force-reencode to override.")

    if config.skip_dolby_vision and info.has_dolby_vision:
        raise RuntimeError("Dolby Vision stream skipped as per configuration")

    content_type = detect_content_type(info)
    crf = config.content_type_crf(content_type) if config.detect_grain else config.crf
    preset = config.content_type_preset(content_type) if config.detect_grain else config.preset

    film_grain = config.svt_film_grain
    if config.detect_grain:
        film_grain = max(film_grain, estimate_grain_level(info))

    output_dir = info.path.parent
    final_destination = output_dir / f"{info.path.stem}.av1.mkv"

    temp_dir = Path(tempfile.mkdtemp(prefix="av1conv-", dir=config.temp_root))
    temp_file = temp_dir / f"{info.path.stem}.tmp.mkv"

    cmd: List[str] = [str(toolchain.ffmpeg)]
    if config.lazy:
        cmd = ["nice", "-n", "10", *cmd]
    cmd.extend([
        "-hide_banner",
        "-y",
        "-i",
        str(info.path),
        "-map",
        f"0:{info.video.index}",
        "-map",
        f"0:{audio_stream.index}",
        "-c:v",
        "libsvtav1",
        "-preset",
        str(preset),
        "-crf",
        str(crf),
        "-g",
        str(config.gop),
        "-pix_fmt",
        "yuv420p10le" if info.is_hdr or (info.video.bits_per_raw_sample or 8) > 8 else "yuv420p",
        "-threads",
        str(config.ffmpeg_threads),
    ])

    if info.is_hdr:
        color_primaries = info.video.color_primaries or "bt2020"
        color_space = info.video.color_space or "bt2020nc"
        color_transfer = info.video.color_transfer or "smpte2084"
        cmd.extend([
            "-color_primaries",
            color_primaries,
            "-colorspace",
            color_space,
            "-color_trc",
            color_transfer,
        ])
        for data in info.video.side_data_list:
            if data.get("side_data_type", "").lower() == "mastering display metadata":
                master = data.get("metadata", {})
                metadata = []
                for key in ("display_primaries_x", "display_primaries_y", "white_point_x", "white_point_y", "min_luminance", "max_luminance"):
                    if key in master:
                        metadata.append(str(master[key]))
                if metadata:
                    cmd.extend(["-master_display", ":".join(metadata)])
            if data.get("side_data_type", "").lower() == "content light level":
                values = data.get("metadata", {})
                if "max_content" in values and "max_average" in values:
                    cmd.extend(["-content_light", f"{values['max_content']}:{values['max_average']}"])
    else:
        if info.video.color_primaries:
            cmd.extend(["-color_primaries", info.video.color_primaries])
        if info.video.color_transfer:
            cmd.extend(["-color_trc", info.video.color_transfer])
        if info.video.color_space:
            cmd.extend(["-colorspace", info.video.color_space])

    if config.resize and info.video.height and info.video.height > config.resize_target_height:
        cmd.extend(["-vf", f"scale=-2:{config.resize_target_height}"])

    if film_grain:
        cmd.extend(["-svtav1-film-grain", str(film_grain)])

    cmd.extend([
        "-svtav1-tune",
        str(config.svt_tune),
        "-svtav1-enable-overlays",
        str(config.svt_enable_overlays),
        "-svtav1-fast-decode",
        str(config.svt_fast_decode),
        "-svtav1-lookahead",
        str(config.svt_lookahead),
        "-svtav1-enable-qm",
        str(config.svt_enable_qm),
        "-svtav1-qm-min",
        str(config.svt_qm_min),
        "-svtav1-qm-max",
        str(config.svt_qm_max),
        "-svtav1-tile-columns",
        str(config.svt_tile_columns),
        "-svtav1-aq-mode",
        str(config.svt_aq_mode),
        "-svtav1-sharpness",
        str(config.svt_sharpness),
    ])

    # Audio encoding parameters
    audio_codec = None
    if config.stereo_downmix:
        cmd.extend(["-ac", "2"])
    if config.audio_bitrate_override:
        cmd.extend(["-b:a", config.audio_bitrate_override])
    if toolchain.supports_libopus:
        audio_codec = "libopus"
    elif toolchain.supports_aac:
        audio_codec = "aac"
    if not audio_codec:
        raise RuntimeError("FFmpeg build lacks both libopus and AAC encoders")
    cmd.extend(["-c:a", audio_codec])
    cmd.extend(["-disposition:a:0", "default"])

    # Subtitle handling
    for sub_index, stream in enumerate(subtitle_streams):
        cmd.extend(["-map", f"0:{stream.index}"])
        codec_opt = "srt" if stream.codec in {"mov_text", "tx3g"} else "copy"
        cmd.extend([f"-c:s:{sub_index}", codec_opt])
        if stream.disposition.get("forced"):
            cmd.extend([f"-disposition:s:{sub_index}", "forced"])

    cmd.extend([
        "-metadata",
        f"encoding_tool=av1conv.py ({config.reencoded_by})",
        "-metadata",
        "encoder=libsvtav1",
        str(temp_file),
    ])

    return EncodePlan(
        source=info.path,
        command=cmd,
        temp_dir=temp_dir,
        temp_file=temp_file,
        final_destination=final_destination,
        source_size=info.size_bytes,
    )


# ---------------------------------------------------------------------------
# Encoding execution
# ---------------------------------------------------------------------------


@dataclass
class EncodeResult:
    source: Path
    destination: Path
    skipped: bool
    reverted: bool
    message: str
    savings_bytes: int = 0


def execute_plan(plan: EncodePlan, config: Config, logger: Logger) -> EncodeResult:
    logger.notice("Running ffmpeg command:\n" + " ".join(shlex.quote(part) for part in plan.command))
    temp_dir = plan.temp_dir
    try:
        subprocess.run(plan.command, check=True)
    except subprocess.CalledProcessError as exc:
        if config.cleanup_on_exit:
            shutil.rmtree(temp_dir, ignore_errors=True)
        raise RuntimeError(f"ffmpeg failed: {exc}")

    if not plan.temp_file.exists():
        if config.cleanup_on_exit:
            shutil.rmtree(temp_dir, ignore_errors=True)
        raise RuntimeError("Temporary output missing after ffmpeg run")

    final_destination = plan.final_destination
    if final_destination.exists():
        logger.warning(f"Overwriting existing file {final_destination}")
        final_destination.unlink()
    shutil.move(str(plan.temp_file), str(final_destination))
    if config.cleanup_on_exit:
        shutil.rmtree(temp_dir, ignore_errors=True)
    else:
        logger.info(f"Preserved temporary directory at {temp_dir}", always=True)

    new_size = final_destination.stat().st_size
    savings = plan.source_size - new_size
    reverted = False

    if new_size >= plan.source_size:
        if config.allow_larger_files:
            logger.warning(
                "Encoded file is larger than original but keeping it as requested "
                f"(+{human_readable_bytes(new_size - plan.source_size)})"
            )
        else:
            logger.warning("Encoded file is larger than original; reverting to source")
            final_destination.unlink()
            reverted = True
            savings = 0

    if reverted:
        if config.cleanup_on_exit:
            pass
        else:
            logger.info(f"Encoded file removed but temporary data kept at {temp_dir}", always=True)
        return EncodeResult(plan.source, plan.source, skipped=True, reverted=True, message="Encoded file larger than source; reverted")

    if config.remove_input_file:
        try:
            plan.source.unlink()
            logger.info(f"Removed source file {plan.source}", always=True)
        except OSError as exc:
            logger.warning(f"Failed to remove source file {plan.source}: {exc}")

    return EncodeResult(plan.source, final_destination, skipped=False, reverted=False, message="Success", savings_bytes=savings)


# ---------------------------------------------------------------------------
# Batch processing and orchestration
# ---------------------------------------------------------------------------


@dataclass
class SessionReport:
    processed: int = 0
    skipped: int = 0
    reverted: int = 0
    total_savings: int = 0
    failures: List[str] = field(default_factory=list)

    def to_json(self) -> str:
        data = dataclasses.asdict(self)
        data["total_savings_human"] = human_readable_bytes(self.total_savings)
        return json.dumps(data, indent=2)


def human_readable_bytes(value: int) -> str:
    if value == 0:
        return "0B"
    negative = value < 0
    value = abs(value)
    units = ["B", "KB", "MB", "GB", "TB"]
    for unit in units:
        if value < 1024:
            break
        value /= 1024
    result = f"{value:.2f}{unit}"
    return f"-{result}" if negative else result


def process_file(path: Path, config: Config, toolchain: FFmpegToolchain, logger: Logger) -> EncodeResult:
    if should_skip_file(path, config) and not config.force:
        logger.info(f"Skipping {path} (filtered by heuristics)", always=True)
        return EncodeResult(path, path, skipped=True, reverted=False, message="Filtered by heuristics")
    info = ffprobe_media(path, toolchain)
    plan = build_encode_plan(info, config, toolchain, logger)
    result = execute_plan(plan, config, logger)
    return result


def process_batch(paths: Sequence[Path], config: Config, toolchain: FFmpegToolchain, logger: Logger) -> SessionReport:
    report = SessionReport()
    lock = threading.Lock()

    def worker(path: Path) -> None:
        nonlocal report
        try:
            result = process_file(path, config, toolchain, logger)
        except Exception as exc:  # pragma: no cover - defensive
            with lock:
                report.failures.append(f"{path}: {exc}")
                report.skipped += 1
            logger.error(f"Failed to process {path}: {exc}")
            return
        with lock:
            if result.skipped:
                report.skipped += 1
            else:
                report.processed += 1
                report.total_savings += result.savings_bytes
            if result.reverted:
                report.reverted += 1
        logger.success(f"Finished {path.name}: {result.message}")

    max_workers = max(1, config.max_parallel_jobs)
    if max_workers == 1:
        for path in paths:
            worker(path)
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            list(executor.map(worker, paths))

    logger.notice(
        f"Summary: processed={report.processed}, skipped={report.skipped}, reverted={report.reverted}, savings={human_readable_bytes(report.total_savings)}"
    )
    return report


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def discover_files(config: Config) -> List[Path]:
    directory = config.directory
    if not directory.exists():
        raise RuntimeError(f"Directory does not exist: {directory}")
    files: List[Path] = []
    for entry in directory.rglob("*"):
        if entry.is_file() and entry.suffix.lower() in _VIDEO_EXTENSIONS:
            files.append(entry)
    return sorted(files)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    config = Config()
    logger = Logger(verbose=args.verbose)

    if args.generate_config:
        target = Path("av1conv.conf")
        generate_sample_config(target)
        logger.success(f"Sample configuration written to {target}")
        return 0

    if args.config:
        load_config_file(args.config, config, logger)
    apply_args_to_config(args, config)

    if args.directory:
        config.directory = Path(args.directory)

    try:
        toolchain = find_ffmpeg(config, logger)
    except Exception as exc:
        logger.error(str(exc))
        return 1

    try:
        config.temp_root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.error(f"Unable to create temporary root {config.temp_root}: {exc}")
        return 1

    if config.detect_grain_test:
        test_path = Path(config.detect_grain_test)
        if not test_path.exists():
            logger.error(f"Detect grain test file not found: {test_path}")
            return 1
        info = ffprobe_media(test_path, toolchain)
        content_type = detect_content_type(info)
        film_grain = estimate_grain_level(info)
        logger.notice(f"Content type heuristic: {content_type}")
        logger.notice(f"Estimated grain strength: {film_grain}")
        return 0

    try:
        files = discover_files(config)
    except Exception as exc:
        logger.error(str(exc))
        return 1

    if not files:
        logger.warning("No video files found to process")
        return 0

    logger.notice(f"Found {len(files)} candidate files")

    report = process_batch(files, config, toolchain, logger)

    if args.generate_report:
        print(report.to_json())

    return 0 if not report.failures else 1


if __name__ == "__main__":  # pragma: no cover - script entry point
    raise SystemExit(main())
