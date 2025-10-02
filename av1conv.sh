#!/usr/bin/env bash

##############################################################################################
# av1conv.sh - Advanced AV1 Video Conversion Script with ML-Based Quality Optimisation
Version="2.6.4"
#
# MAJOR FEATURES IN VERSION 2.6.4:
# - FIXED: Proper bit-depth detection - no longer forces 10-bit for 8-bit sources (major AV1 efficiency gain)
# - FIXED: Corrected SVT-AV1 tune parameter documentation (0=subjective, 1=PSNR, no VMAF tune exists)
# - REMOVED: Non-functional SCD (scene change detection) parameter completely stripped from script
# - DISABLED: Overlays parameter disabled by default (potential quality/seeking harm per r/AV1 community)
# - UPDATED: Lookahead range corrected to 0-32 (was incorrectly allowing up to 240)
# - OPTIMISED: GOP reduced from 300 to 120 frames (4sec keyframes for better Jellyfin/Plex seeking)
# - IMPROVED: Presets optimised for quality/speed balance (5/5/4 instead of 6/6/6, per CommonQuestions.md)
# - REVERTED: Film grain disabled by default (enabled only when explicitly set)
#
# PREVIOUS FEATURES IN VERSION 2.6.3:
# - Removed experimental hardware acceleration path to focus on quality-first SVT-AV1
# - Dolby Vision profiles 7/8 automatically converted to HDR10 (RPUs stripped)
# - Refined default CRF ladder (28/26/22/29) to smooth dark scenes without bloating files
# - Smarter grain handling with AQ biasing and tighter thread management
#
# MAJOR FEATURES IN VERSION 2.6.2:
# - Fixed configuration handling and expanded format support
# - Extended video format support: added MXF, WMV, FLV, 3GP, ASF, VOB, RM/RMVB, F4V, DivX, XviD
# - Improved file discovery for professional and legacy video formats
# - Enhanced subtitle codec handling with automatic mov_text to SRT conversion for MKV compatibility
# - Added subtitle codec validation to prevent encoding failures from unsupported formats
#
# MAJOR FEATURES IN VERSION 2.6.1:
# - Configurable language preferences for audio and subtitle tracks
# - Improved audio codec selection (Opus-first with AAC fallback) 
# - Enhanced missing file handling with notifications and terminal alerts
# - Added experimental hardware acceleration support
# - Robust error handling and audio stream validation
# - Smart forced subtitle detection and handling
#
# CORE CAPABILITIES:
# - ML-based content analysis for optimal encoding settings (Film/TV/Animation)
# - Parallel processing support with real-time progress monitoring
# - Comprehensive HDR/metadata preservation (Dolby Vision profiles 7/8 to HDR10)
# - Intelligent audio transcoding with optimal bitrates per channel configuration
# - Advanced subtitle processing with language-aware selection
#
# Author: geekphreek (and a little Claude magic for when it gets too much)
#
# Info: This script represents significant development time focused on reliability,
#       performance, and user experience. Please review configuration options and
#       help documentation before use.
#       If you find it useful, consider buying me a coffee: https://ko-fi.com/geekphreek
#
# --detect-grain is experimental and may not work perfectly on all files.
##############################################################################################

## Let's begin ##

# Make the script panic properly when things go wrong
set -euo pipefail

# Global variables for interrupt handling
declare -g interrupt_count=0
declare -g last_interrupt_time=0
declare -g should_exit_queue=false

# Reset the terminal colours on script exit
reset_terminal_colours() {
    printf "\033[0m" >&2
}

# Enhanced interrupt handler with double Ctrl+C detection
handle_interrupt() {
    local current_time
    current_time=$(date +%s)
    
    # Check if this is within 3 seconds of the last interrupt
    if (( current_time - last_interrupt_time <= 3 )); then
        interrupt_count=$((interrupt_count + 1))
    else
        interrupt_count=1
    fi
    
    last_interrupt_time=$current_time
    
    if (( interrupt_count >= 2 )); then
        printf "\n\033[33mDouble Ctrl+C detected - exiting entire queue...\033[0m\n" >&2
        should_exit_queue=true
        interrupt_count=0
        exit 130
    else
        printf "\n\033[33mCtrl+C: Skipping current file... (press Ctrl+C again within 3 seconds to exit queue)\033[0m\n" >&2
    fi
}

trap reset_terminal_colours EXIT
trap handle_interrupt INT TERM

# ============================================================================
# CONFIGURATION SYSTEM
# ============================================================================

# Something start at zero
declare -g total_space_saved=0
declare -g overall_start_time=0
declare -g total_original_bytes=0
declare -g total_final_bytes=0
declare -ga reverted_files=()  # Track files where AV1 was larger than original

# Default configuration - these are the fallback values if nothing else is specified
set_default_config() {
    # Core settings - the bread and butter options
    directory="/mnt/movies/"
    verbose=false
    preset=5            # Optimised for quality/speed balance (4-6 recommended)
    animation_preset=6  # Default preset override for animation content
    tv_preset=5         # Default preset override for TV content
    film_preset=4       # Default preset override for film content (preserve grain)
    max_parallel_jobs=1 # Number of parallel encoding jobs (1=sequential, 2=parallel)
    crf=28
    gop=120     # 4 seconds at 30fps - optimised for Jellyfin/Plex seeking
    size="1G"
    remove_input_file=false
    lazy=false
    av1=false
    allow_larger_files=false
    force=false
    ignore=false
    force_reencode=false
    resize=false
    resize_target_height=1080 # Default target height used when resize=true
    ffmpeg_threads=6       # Auto-capped to available cores (max 16)
    detect_grain=false
    detect_grain_test=false
    detect_grain_test_file=""
    temp_root="/tmp"
    cleanup_on_exit=true
    reencoded_by="geekphreek" # change this to your own name!
    skip_dolby_vision=false
    skipped_files=0
    missing_files=0
    stereo_downmix=false
    audio_bitrate_override=""

    # ML Grain Detection CRF Settings - content-type specific quality targets
    crf_animation=29       # Animation: heavy denoise, no synthetic grain
    crf_film=22            # Film: preserve original grain characteristics  
    crf_tv=26              # TV: moderate denoise + light synthetic grain

    # ML Content Type Preset Overrides (0-12, used when ML detector identifies content)
    animation_preset=6    # Animation content (good balance)
    tv_preset=5           # TV show content (balance speed vs quality)
    film_preset=4         # Film content (preserve grain, slower presets)

    # SVT-AV1 specific parameters - the fancy stuff
    svt_tune=1
    svt_enable_overlays=0  # Potentially harmful to quality/seeking performance
    svt_fast_decode=1     # Optimised for decode performance
    svt_lookahead=32      # Effective range is 0-32, higher values provide no benefit
    svt_enable_qm=1
    svt_qm_min=0
    svt_qm_max=15
    svt_tile_columns=2    # Better multithreaded decoding (minimal quality impact)
    svt_film_grain=0      # Film grain disabled by default
    svt_aq_mode=2
    svt_sharpness=0

    # FFmpeg path - leave empty to auto-detect
    personal_ffmpeg_path=""
    
    # Audio codec - determined at startup based on availability
    preferred_audio_codec=""
    
    # Language preferences
    preferred_audio_language="eng"  # Primary audio language (3-letter code)
    preferred_subtitle_language="eng"  # Primary subtitle language (3-letter code)
    forced_subtitles_only=true  # Only include forced/SDH subtitles by default
}

# Find config file in logical places
find_config_file() {
    local script_path script_dir config_candidates config_file=""
    
    # Resolve symlinks to get the real script location
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    script_dir="$(dirname "$script_path")"
    
    # Priority order for config file locations
    config_candidates=(
        "${AV1CONV_CONFIG:-}"                    # Environment variable override
        "$script_dir/av1conv.conf"               # Same directory as REAL script
        "$HOME/.config/av1conv/av1conv.conf"     # User config directory (XDG standard)
        "$HOME/.av1conv.conf"                    # User home directory (traditional)
        "/etc/av1conv/av1conv.conf"              # System-wide config
        "/usr/local/etc/av1conv.conf"            # Local system config
    )
    
    for candidate in "${config_candidates[@]}"; do
        # Skip empty candidates
        [[ -z "$candidate" ]] && continue
        
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            config_file="$candidate"
            log "Found config file: $config_file" "32"
            break
        fi
    done
    
    echo "$config_file"
}

# Load and validate config file - with proper error handling because we're not animals
load_config_file() {
    local config_file="$1"
    
    if [[ -z "$config_file" ]]; then
        log "No config file found, using defaults" "33"
        return 0
    fi
    
    log "Loading configuration from: $config_file" "34"
    
    # Create a temporary environment to test the config
    local temp_file
    temp_file=$(mktemp)
    
    # Validate config syntax before sourcing - prevent script explosion
    if ! bash -n "$config_file" 2>"$temp_file"; then
        log "ERROR: Config file has syntax errors:" "31" true
        cat "$temp_file" >&2
        rm -f "$temp_file"
        return 1
    fi
    
    rm -f "$temp_file"
    
    # Source the config file in a subshell first to catch any runtime errors
    local test_output
    if ! test_output=$(bash -c "source '$config_file' 2>&1"); then
        log "ERROR: Config file failed to load:" "31" true
        echo "$test_output" >&2
        return 1
    fi
    
    # Config looks good, source it for real
    source "$config_file"
    
    log "Configuration loaded successfully" "32"
    return 0
}

# Validate configuration values - I do not trust your settings!
validate_config() {
    local errors=()
    
    # Directory validation
    if [[ ! -d "$directory" ]]; then
        log "WARNING: Directory '$directory' does not exist" "31"
    fi
    
    # Size format validation
    if [[ ! $size =~ ^[0-9]+[KMGTP]?$ ]]; then
        errors+=("Size must be a positive number optionally followed by K, M, G, T, or P (got: $size)")
    else
        # Normalize size - add G if no suffix provided
        if [[ ! $size =~ [KMGTP]$ ]]; then
            size="${size}G"
            log "Normalized size to: $size" "33"
        fi
    fi
    
    # Actual Min/Max for the settings - I believe this are currently correct
    if ! [[ $crf =~ ^[0-9]+$ ]] || [[ $crf -lt 0 || $crf -gt 63 ]]; then
        errors+=("CRF must be an integer between 0 and 63 (got: $crf)")
    fi
    
    if ! [[ $preset =~ ^-?[0-9]+$ ]] || [[ $preset -lt -1 || $preset -gt 13 ]]; then
        errors+=("Preset must be an integer between -1 and 13 (got: $preset)")
    fi
    
    if ! [[ $animation_preset =~ ^-?[0-9]+$ ]] || [[ $animation_preset -lt -1 || $animation_preset -gt 13 ]]; then
        errors+=("Animation preset must be an integer between -1 and 13 (got: $animation_preset)")
    fi

    if ! [[ $tv_preset =~ ^-?[0-9]+$ ]] || [[ $tv_preset -lt -1 || $tv_preset -gt 13 ]]; then
        errors+=("TV preset must be an integer between -1 and 13 (got: $tv_preset)")
    fi

    if ! [[ $film_preset =~ ^-?[0-9]+$ ]] || [[ $film_preset -lt -1 || $film_preset -gt 13 ]]; then
        errors+=("Film preset must be an integer between -1 and 13 (got: $film_preset)")
    fi
    
    if ! [[ $max_parallel_jobs =~ ^[0-9]+$ ]] || [[ $max_parallel_jobs -lt 1 || $max_parallel_jobs -gt 4 ]]; then
        errors+=("Max parallel jobs must be an integer between 1 and 4 (got: $max_parallel_jobs)")
    fi
    
    if ! [[ $gop =~ ^[0-9]+$ ]] || [[ $gop -lt 0 || $gop -gt 500 ]]; then
        errors+=("GOP must be an integer between 0 and 500 (got: $gop)")
    fi
    
    if ! [[ $ffmpeg_threads =~ ^[0-9]+$ ]] || [[ $ffmpeg_threads -lt 1 || $ffmpeg_threads -gt 64 ]]; then
        errors+=("FFmpeg threads must be an integer between 1 and 64 (got: $ffmpeg_threads)")
    fi
    
    # Audio bitrate validation (if set)
    if [[ -n "$audio_bitrate_override" && ! "$audio_bitrate_override" =~ ^[0-9]+k$ ]]; then
        errors+=("Audio bitrate must end with 'k' (e.g., 128k) (got: $audio_bitrate_override)")
    fi
    
    # SVT-AV1 parameter validation - these are quite specific
    if ! [[ $svt_tune =~ ^[0-3]$ ]]; then
        errors+=("SVT tune must be 0 (VQ), 1 (PSNR), 2 (SSIM), or 3 (IQ) (got: $svt_tune)")
    fi
    
    if ! [[ $svt_enable_overlays =~ ^[0-1]$ ]]; then
        errors+=("SVT enable-overlays must be either 0 or 1 (got: $svt_enable_overlays)")
    fi
    
    
    if ! [[ $svt_fast_decode =~ ^[0-2]$ ]]; then
        errors+=("SVT fast-decode must be 0, 1, or 2 (got: $svt_fast_decode)")
    fi
    
    if ! [[ $svt_lookahead =~ ^[0-9]+$ ]] || [[ $svt_lookahead -lt 0 || $svt_lookahead -gt 32 ]]; then
        errors+=("SVT lookahead must be between 0 and 32 (got: $svt_lookahead)")
    fi
    
    if ! [[ $svt_enable_qm =~ ^[0-1]$ ]]; then
        errors+=("SVT enable-qm must be either 0 or 1 (got: $svt_enable_qm)")
    fi
    
    if ! [[ $svt_qm_min =~ ^[0-9]+$ ]] || [[ $svt_qm_min -lt 0 || $svt_qm_min -gt 15 ]]; then
        errors+=("SVT qm-min must be between 0 and 15 (got: $svt_qm_min)")
    fi
    
    if ! [[ $svt_qm_max =~ ^[0-9]+$ ]] || [[ $svt_qm_max -lt 0 || $svt_qm_max -gt 15 ]]; then
        errors+=("SVT qm-max must be between 0 and 15 (got: $svt_qm_max)")
    fi
    
    if [[ $svt_qm_min -gt $svt_qm_max ]]; then
        errors+=("SVT qm-min ($svt_qm_min) cannot be greater than qm-max ($svt_qm_max)")
    fi
    
    if ! [[ $svt_tile_columns =~ ^[0-9]+$ ]] || [[ $svt_tile_columns -lt 0 || $svt_tile_columns -gt 4 ]]; then
        errors+=("SVT tile-columns must be between 0 and 4 (got: $svt_tile_columns)")
    fi
    
    if ! [[ $svt_film_grain =~ ^[0-9]+$ ]] || [[ $svt_film_grain -lt 0 || $svt_film_grain -gt 50 ]]; then
        errors+=("SVT film-grain must be between 0 and 50 (got: $svt_film_grain)")
    fi
    
    # Temp directory validation test
    if [[ ! -d "$temp_root" ]]; then
        log "WARNING: Temporary directory '$temp_root' does not exist" "31"
    elif [[ ! -w "$temp_root" ]]; then
        errors+=("Temporary directory '$temp_root' is not writable")
    fi
    
    # Report any errors found
    if [[ ${#errors[@]} -gt 0 ]]; then
        log "Configuration validation errors:" "31" true
        printf '%s\n' "${errors[@]}" | sed 's/^/  /' >&2
        return 1
    fi
    
    return 0
}

# Display current configuration
display_config() {
    local force_display="${1:-false}"
    
    if [[ $verbose == true || $force_display == true ]]; then
        local config_file
        config_file=$(find_config_file)
        
        # Header with source info
        echo "AV1 Conversion Configuration"
        echo "============================"
        
        if [[ -n "$config_file" ]]; then
            echo "Source: $config_file + CLI overrides"
        else
            echo "Source: Built-in defaults + CLI overrides"
            echo "Create: Run '$(basename "$0") --generate-config' for custom settings"
        fi
        
        echo
        echo "Quality & Encoding:"
        printf "   Preset: %-3s CRF: %-3s GOP: %-4s Grain: %s\n" "$preset" "$crf" "$gop" "$svt_film_grain"
        printf "   Tune: %s  Overlays: %s  QM: %s-%s\n" \
            "$(case "$svt_tune" in 0) echo "VQ";; 1) echo "PSNR";; 2) echo "SSIM";; 3) echo "IQ";; *) echo "Unknown";; esac)" \
            "$svt_enable_overlays" "$svt_qm_min" "$svt_qm_max"
        
        echo
        echo "Files & Processing:"
        printf "   Directory: %s\n" "$directory"
        printf "   Min size: %-4s Threads: %-3s Remove: %s\n" "$size" "$ffmpeg_threads" "$remove_input_file"
        printf "   Force AV1: %-6s Resize: %-6s Lazy: %s\n" "$av1" "$resize" "$lazy"
        printf "   Allow larger: %-6s\n" "$allow_larger_files"
        if [[ "$resize" == true ]]; then
            printf "   Resize target: %sp\n" "$resize_target_height"
        fi
        
        echo
        echo "Audio & Extras:"
        printf "   Stereo mix: %-6s Bitrate: %s\n" "$stereo_downmix" "${audio_bitrate_override:-"auto"}"
        printf "   Skip DV: %-8s Temp: %s\n" "$skip_dolby_vision" "$temp_root"
        
        if [[ "$detect_grain" == true ]]; then
            echo
            echo "ML Grain Detection CRF:"
            printf "   Animation: %-3s Film: %-3s TV: %s\n" "$crf_animation" "$crf_film" "$crf_tv"
        fi
        
        # Ignore spaces - trying to keep things aligned
        if [[ $force_display == true && -z "$config_file" ]]; then
            echo
            echo "Quick Setup:"
            echo "   $(basename "$0") --generate-config         # Create template"
            echo "   nano av1conv.conf.sample             # Edit settings"  
            echo "   mv av1conv.conf.sample av1conv.conf  # Activate"
        fi
    fi
}

# Generate a sample config file - lots of info because some of you read
generate_sample_config() {
    local output_file="${1:-av1conv.conf.sample}"
    
    cat > "$output_file" << 'EOF'
# AV1 Conversion Script Configuration File
# ========================================
#
# This file contains all the configurable options for the AV1 conversion script.
# You can copy this file to one of these locations (in order of priority):
#   1. Same directory as the script: av1conv.conf
#   2. User config directory: ~/.config/av1conv/av1conv.conf
#   3. User home directory: ~/.av1conv.conf
#   4. System-wide: /etc/av1conv/av1conv.conf
#
# All values shown here are the defaults. Uncomment and modify as needed.
# CLI arguments will override these settings. You do NOT have to have a config file.

# ============================================================================
# CORE SETTINGS
# ============================================================================

# Directory to scan for video files
#directory="/mnt/movies/"

# Enable verbose output (true/false)
#verbose=false

# SVT-AV1 preset (-1 to 13, lower = slower/better quality, 4-6 recommended)
#preset=5

# ML Content Type Preset Overrides (-1 to 13, used when ML detector identifies content)
#animation_preset=6    # Animation content (good balance)
#tv_preset=5          # TV show content (balance speed vs quality)
#film_preset=4        # Film content (preserve grain, slower presets)

# Parallel Processing (requires 'column' command for side-by-side display)
#max_parallel_jobs=1   # Number of concurrent encodes (1=sequential, 2=parallel)

# Constant Rate Factor (0-63, lower = better quality)
#crf=28

# Group of Pictures size (keyframe interval, 4 seconds @ 30fps for streaming)
#gop=120

# Minimum file size to process (e.g., "500M", "1G", "2G")
#size="1G"

# Remove original file after successful encoding (true/false)
#remove_input_file=false

# Run with lower CPU priority (true/false)
#lazy=false

# Force AV1 encoding for all files (true/false)
#av1=false

# Allow AV1 files to be kept even if larger than original (true/false)
#allow_larger_files=false

# Process files without prompting (true/false)
#force=false

# Ignore CAM/WORKPRINT/TELESYNC files (true/false)
#ignore=false

# Force re-encoding even if already AV1 (true/false)
#force_reencode=false

# Resize videos if source is higher (true/false)
#resize=false
# Target height when resizing (e.g., 1080 or 720)
#resize_target_height=1080

# Number of threads for FFmpeg to use (auto-capped to available cores, max 16)
#ffmpeg_threads=6

# Automatically detect and preserve film grain (true/false)
#detect_grain=false

# Testing mode for grain detection (true/false)
#detect_grain_test=false

# Specific file for grain detection testing
#detect_grain_test_file=""

# ML Grain Detection CRF Settings - content-type specific quality targets
# Lower CRF = higher quality/larger files. Script only lowers CRF, never raises it.
#crf_animation=29       # Animation: heavy denoise, no synthetic grain
#crf_film=22            # Film: preserve original grain characteristics  
#crf_tv=26              # TV: moderate denoise + light synthetic grain

# Temporary directory for encoding
#temp_root="/tmp"

# Clean up temporary files on exit (true/false)
#cleanup_on_exit=true

# Name to embed in "encoded by" metadata - please change this to your name
#reencoded_by="geekphreek"

# Skip Dolby Vision files entirely (true/false)
# When false (default) profiles 7/8 are converted as HDR10 with RPUs stripped
#skip_dolby_vision=false

# Downmix multi-channel audio to stereo (true/false)
#stereo_downmix=false

# Override audio bitrate (e.g., "128k", "192k", "256k")
#audio_bitrate_override=""

# Internal counter for skipped files (do not modify)
#skipped_files=0

# Internal counter for missing files (do not modify)
#missing_files=0

# ============================================================================
# LANGUAGE PREFERENCES
# ============================================================================

# Preferred audio language (3-letter ISO 639-2 code)
#preferred_audio_language="eng"

# Preferred subtitle language (3-letter ISO 639-2 code) 
#preferred_subtitle_language="eng"

# Only include forced subtitles by default (true/false)
#forced_subtitles_only=true

# ============================================================================
# SVT-AV1 ADVANCED SETTINGS
# ============================================================================

# Tune for VQ (0), PSNR (1), SSIM (2), or IQ (3)
#svt_tune=1

# Enable overlays (0/1)
#svt_enable_overlays=1


# Fast decode mode (0/1/2, 1 recommended for decode performance)
#svt_fast_decode=1

# Lookahead frames (0-32, higher values provide no benefit)
#svt_lookahead=32

# Enable quantization matrices (0/1)
#svt_enable_qm=1

# Quantization matrix minimum (0-15)
#svt_qm_min=0

# Quantization matrix maximum (0-15)
#svt_qm_max=15

# Number of tile columns (0-4, 2 recommended for multithreaded decoding)
#svt_tile_columns=2

# Film grain synthesis level (0-50, 4-15 recommended range)
#svt_film_grain=0

# Adaptive quantization mode (0-2)
#svt_aq_mode=2

# Sharpness control (0-7)
#svt_sharpness=0

# ============================================================================
# FFMPEG SETTINGS
# ============================================================================

# Path to custom FFmpeg binary (leave empty for auto-detection)
#personal_ffmpeg_path=""

# Examples of custom paths:
#personal_ffmpeg_path="/usr/lib/jellyfin-ffmpeg/ffmpeg"
#personal_ffmpeg_path="/opt/ffmpeg/bin/ffmpeg"
#personal_ffmpeg_path="/usr/local/bin/ffmpeg"
EOF

    log "Sample configuration file generated: $output_file" "32" true
    log "Edit this file and save it as 'av1conv.conf' to customise your settings" "32" true
}

# Initialise configuration system - the main orchestrator
initialise_config() {
    # Step 1: Set sensible defaults
    set_default_config
    log "Default configuration loaded" "33"
    
    # Step 2: Show script location debug info (only during actual loading)
    local script_path script_dir
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    script_dir="$(dirname "$script_path")"
    
    log "Script symlink: ${BASH_SOURCE[0]}" "33"
    log "Script real path: $script_path" "33"
    log "Script directory: $script_dir" "33"
    
    # Step 3: Load config file if available
    #         You don't need a config file
    local config_file
    config_file=$(find_config_file)
    
    if [[ -n "$config_file" ]]; then
        if ! load_config_file "$config_file"; then
            log "Failed to load config file, using defaults" "31"
            return 1
        fi
        log "Configuration loaded from: $config_file" "32"
    else
        log "No config file found, using built-in defaults" "33"
        log "Tip: Run '--generate-config' to create a customisable config file" "33"
    fi
    
    return 0
}

# Dependencies we need to make the magic happen - sorry this has got so long
dependencies=("ffprobe" "ffmpeg" "nice" "numfmt" "find" "awk" "mkvpropedit" "jq" "parallel" "mktemp" "stat" "grep" "cut" "head" "tail" "sed" "tr" "readlink")

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# If you didn't specify a personal path for ffmpeg, this hunts one down
find_ffmpeg() {
    local ffmpeg_candidates=(
        "$personal_ffmpeg_path"              # User's personal choice (if set)
        "/usr/lib/jellyfin-ffmpeg/ffmpeg"    # Jellyfin's optimised build
        "/opt/ffmpeg/bin/ffmpeg"             # Custom compiled installations
        "/usr/local/bin/ffmpeg"              # Local builds
        "$HOME/.local/bin/ffmpeg"            # User-local installations
        "/snap/bin/ffmpeg"                   # Snap packages - urgh!
        "$(command -v ffmpeg 2>/dev/null)"   # Whatever's in PATH
        "/usr/bin/ffmpeg"                    # System package
    )
    
    log "Hunting for FFmpeg installations..." "34" true
    
    local found_ffmpeg=""
    local ffmpeg_info=""
    
    for candidate in "${ffmpeg_candidates[@]}"; do
        # Skip empty candidates
        [[ -z "$candidate" ]] && continue
        
        log "Checking: $candidate" "33"
        
        if [[ -x "$candidate" ]]; then
            # Test if it actually works and get version info
            if ffmpeg_info=$("$candidate" -version 2>/dev/null | head -n1); then
                found_ffmpeg="$candidate"
                log "[+] Found working FFmpeg: $candidate" "32" true
                log "  Version: $ffmpeg_info" "32" true
                break
            else
                log "[-] Found but non-functional: $candidate" "31"
            fi
        else
            log "[-] Not found or not executable: $candidate" "33"
        fi
    done
    
    if [[ -z "$found_ffmpeg" ]]; then
        log "ERROR: No working FFmpeg installation found!" "31" true
        log "Please install FFmpeg or set personal_ffmpeg_path to a valid installation" "31" true
        return 1
    fi
    
    # Check for SVT-AV1 support - The whole point of this script
    local svt_check
    svt_check=$("$found_ffmpeg" -encoders 2>&1 | grep -i "libsvtav1" || true)
    
    if [[ -n "$svt_check" ]]; then
        log "[+] FFmpeg has SVT-AV1 encoder support - excellent!" "32" true
        log "  Found: $(echo "$svt_check" | sed 's/^[[:space:]]*//')" "33" true
    else
        log "WARNING: FFmpeg lacks SVT-AV1 encoder support!" "31" true
        log "You'll need an FFmpeg build with libsvtav1 for AV1 encoding" "31" true
        log "Debugging - encoder check output:" "33" true
        "$found_ffmpeg" -encoders 2>&1 | head -20 >&2
        return 1
    fi
    
    # Set the global variable
    ffmpeg_path="$found_ffmpeg"
    
    # Show some useful info about what we found
    local ffmpeg_type=""
    case "$found_ffmpeg" in
        *jellyfin*) ffmpeg_type="Jellyfin build (optimised for media)" ;;
        *snap*) ffmpeg_type="Snap package" ;;
        */usr/local/*) ffmpeg_type="Local build" ;;
        */.local/*) ffmpeg_type="User-local installation" ;;
        */opt/*) ffmpeg_type="Custom installation" ;;
        */usr/bin/*) ffmpeg_type="System package" ;;
        *) ffmpeg_type="Unknown type" ;;
    esac
    
    log "Using FFmpeg: $ffmpeg_type" "32" true
    return 0
}

# Logging with style and timestamp
log() {
    local message="$1"
    local colour="${2:-}"
    local force_output="${3:-false}"
    if [[ $verbose == true || $force_output == true || "$colour" == "31" ]]; then  # 31 is red
        if [[ -n "$colour" ]]; then
            printf "\033[%sm%s\033[0m\n" "$colour" "$message" >&2
        else
            printf "%s\n" "$message" >&2
        fi
    fi
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "/tmp/encode.log"
}

# Help text - RTFM - I'm sorry this has become a monster
display_help() {
    cat << EOF
Usage: ${0##*/} [options]

AV1 Video Conversion Script with Configuration File Support
==========================================================

CONFIGURATION:
  The script uses a cascading configuration system:
  1. Built-in defaults (fallback values)
  2. Configuration file (if found)
  3. Command line arguments (highest priority)

  Config file locations (checked in order):
    - Same directory as script: av1conv.conf
    - User config: ~/.config/av1conv/av1conv.conf
    - User home: ~/.av1conv.conf
    - System-wide: /etc/av1conv/av1conv.conf
    - Environment: \$AV1CONV_CONFIG

GENERAL OPTIONS:
  -h, --help               Display this help message and exit
  -v, --verbose            Enable verbose output
  --generate-config [FILE] Generate sample config file (default: av1conv.conf.sample)
  --show-config            Display current configuration and exit
  --config FILE            Use specific config file (sets AV1CONV_CONFIG)

CORE ENCODING OPTIONS:
  -d, --dir DIR            Specify the directory to scan (default: /mnt/movies/)
  -1, --av1                Force AV1 encoding for all files
  -f, --force              Process files without prompting
  -F, --force-reencode     Force re-encoding even if files are already in AV1 format
  -c, --crf VALUE          Set CRF value (default: 28)
  -p, --preset VALUE       Set preset value (default: 5, range: -1 to 13)
  -J, --parallel VALUE     Set number of parallel encoding jobs (default: 1)
  -g, --gop VALUE          Set GOP size (default: 120, 4sec @ 30fps for streaming)
  -i, --ignore             Ignore certain file types (e.g., CAM, WORKPRINT, TELESYNC)
  -l, --lazy               Run ffmpeg with 'nice' for lower CPU priority
  -s, --size VALUE         Minimum file size to process (e.g., 500M, 1G; default: 1G)
  -r, --remove             Remove the input file after successful encoding
  -R, --resize-1080p       Resize videos to 1080p if source resolution is higher
      --resize-720p        Resize videos to 720p if source resolution is higher
      --allow-larger       Keep AV1 files even if larger than original
  --temp-dir DIR           Specify custom temporary directory (default: /tmp)
  --keep-temp              Don't clean up temporary files (for debugging)

AUDIO OPTIONS:
  --stereo                 Downmix audio to stereo
  -ab, --audiobitrate      Set audio bitrate - don't forget the k (e.g., 192k)

SVT-AV1 SPECIFIC OPTIONS:
  --svt-tune VALUE         Set tune value (default: 1 - PSNR) [0=VQ, 1=PSNR, 2=SSIM, 3=IQ]
  --svt-overlays VALUE     Enable/disable overlays (default: 0, may harm quality/seeking)
  --svt-fast-decode VALUE  Set fast decode value (default: 1, optimized for decoding)
  --svt-lookahead VALUE    Set lookahead frames (default: 32, max effective: 32)
  --svt-enable-qm VALUE    Enable quantization matrices (default: 1)
  --svt-qm-min VALUE       Set min quantization matrix value (default: 0)
  --svt-qm-max VALUE       Set max quantization matrix value (default: 15)
  --svt-tile-columns VALUE Set number of tile columns (default: 2, better multithreaded decoding)

FILM GRAIN OPTIONS:
  --svt-film-grain VALUE   Set film grain level (0-50, default: 0, recommended: 4-15)
  --detect-grain           Enable automatic film grain detection (default: disabled)
  --no-detect-grain        Disable automatic film grain detection
  --detect-grain-test FILE Test grain detection on a single file and show verdict

  ML GRAIN DETECTION CRF SETTINGS (configurable in av1conv.conf):
    crf_animation=29       # CRF for animation content (heavy denoise, no grain)
    crf_film=22            # CRF for film content (preserve grain characteristics)
    crf_tv=26              # CRF for TV content (moderate denoise + light grain)

EXAMPLES:
  ${0##*/} --generate-config          # Create a sample config file
  ${0##*/} -d /media/videos -v        # Scan different directory with verbose output
  ${0##*/} --config ~/my-settings.conf -f  # Use custom config and force processing
  ${0##*/} --detect-grain-test movie.mkv   # Test grain detection on a single file

NOTES:
  - All output files will be in Matroska (.mkv) format
  - English audio is set as default track
  - Dolby Vision profile 7/8 titles are converted to HDR10 (RPUs stripped); profile 5 is skipped
  - Config file uses bash syntax: variable=value (no spaces around =)
EOF
}

# ============================================================================
# SETUP AND VALIDATION FUNCTIONS
# ============================================================================

# Create and manage temporary directory
setup_temp_directory() {
    temp_dir=$(mktemp -d "${temp_root}/av1conv.XXXXXXXXXX")
    if [[ ! -d "$temp_dir" ]]; then
        log "Failed to create temporary directory" "31" true
        exit 1
    fi
    log "Created temporary directory: $temp_dir" "32"
    
    if [[ $cleanup_on_exit == true ]]; then
        trap cleanup_temp_directory EXIT
    fi
}

cleanup_temp_directory() {
    # Simple terminal reset - avoid complex escape sequences
    echo  # Ensure we're on a fresh line
    stty sane 2>/dev/null   # Reset terminal settings
    tput sgr0 2>/dev/null   # Reset text attributes using terminfo
    
    if [[ -d "$temp_dir" ]]; then
        log "Cleaning up temporary directory: $temp_dir" "33"
        rm -rf "$temp_dir"
    fi
    
    echo "Cleanup complete."
}

# Cap ffmpeg thread usage to something sensible for the host
cap_ffmpeg_threads() {
    local hw_threads hard_cap target_cap

    if hw_threads=$(nproc 2>/dev/null); then
        hard_cap=16
        target_cap=$hw_threads
        if (( hard_cap > 0 && hard_cap < target_cap )); then
            target_cap=$hard_cap
        fi
    else
        # If nproc fails, fall back to a conservative cap
        target_cap=16
    fi

    (( target_cap < 1 )) && target_cap=1

    if (( ffmpeg_threads > target_cap )); then
        log "Capping ffmpeg threads from $ffmpeg_threads to $target_cap" "33" true
        ffmpeg_threads=$target_cap
    fi
}

# Make sure we've got all our tools
check_dependencies() {
    # Hunt down FFmpeg first - most critical dependency
    if ! find_ffmpeg; then
        log "Cannot proceed without a working FFmpeg installation" "31" true
        exit 1
    fi

    cap_ffmpeg_threads

    # Check for ffprobe (usually comes with ffmpeg but let's be thorough)
    if ! command -v ffprobe &> /dev/null; then
        # Try the same directory as our found ffmpeg
        local ffprobe_path="${ffmpeg_path%/*}/ffprobe"
        if [[ -x "$ffprobe_path" ]]; then
            log "Found ffprobe alongside FFmpeg: $ffprobe_path" "32" true
        else
            log "ERROR: ffprobe not found and required for media analysis" "31" true
            exit 1
        fi
    fi
    
    # Check other dependencies - these should be standard on most systems
    local missing_deps=()
    for dep in "nice" "numfmt" "find" "awk" "mkvpropedit" "jq" "parallel"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check for stdbuf if parallel jobs > 1 (needed for real-time output)
    if [[ $max_parallel_jobs -gt 1 ]] && ! command -v "stdbuf" &> /dev/null; then
        missing_deps+=("stdbuf")
    fi
    
    # Check for column command if parallel jobs > 1 (needed for side-by-side display)
    if [[ $max_parallel_jobs -gt 1 ]] && ! command -v "column" &> /dev/null; then
        missing_deps+=("column")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR: Missing required dependencies:" "31" true
        printf '%s\n' "${missing_deps[@]}" | sed 's/^/  /' >&2
        log "Please install missing packages and try again" "31" true
        exit 1
    fi
    
    # Check audio encoder availability once at startup
    log "Checking audio encoder availability..." "34"
    if ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.1 -c:a libopus -f null - &>/dev/null; then
        preferred_audio_codec="libopus"
        log "[+] Opus encoder available - excellent quality and compression!" "32" true
    elif ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.1 -c:a aac -f null - &>/dev/null; then
        preferred_audio_codec="aac"
        log "[+] AAC encoder available - good compatibility" "33" true
        log "Note: Opus would provide better quality/compression if available" "33" true
    else
        log "ERROR: Neither Opus nor AAC audio encoders are available!" "31" true
        log "Your FFmpeg build lacks essential audio encoding support" "31" true
        exit 1
    fi
    
    log "All dependencies satisfied - ready to encode!" "32" true
}

# ========================
# VIDEO ANALYSIS FUNCTIONS
# ========================

# Let's get everything we need about a file to process it
get_comprehensive_video_info() {
    local file="$1"
    local info_json
    
    # One ffprobe call to rule them all - now with EVEN MORE data!
    # This beast gets video info, audio info, side data, tags, and dispositions in one hit
    if ! info_json=$(ffprobe -v error \
        -show_entries "format=duration:\
stream=index,codec_name,codec_type,profile,pix_fmt,width,height,bit_rate,channels,channel_layout,color_transfer,color_space,color_primaries,r_frame_rate,avg_frame_rate:\
stream_side_data:\
stream_tags=ENCODER:\
stream_disposition=default" \
        -of json "$file" 2>&1); then
        echo "ERROR:CORRUPT_FILE"
        return 1
    fi
    
    # Extract all the video stream values we need
    local codec_name width height color_transfer color_space color_primaries color_range framerate duration
    local v_pix v_fps a_codec a_profile # Additional values for grain detection
    local dv_profile dv_bl_compat dv_el_present dv_rpu_present
    
    codec_name=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.codec_name // "unknown")')
    width=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.width // 0)')
    height=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.height // 0)')
    color_transfer=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.color_transfer // "unknown")')
    color_space=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.color_space // "unknown")')
    color_primaries=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.color_primaries // "unknown")')
    framerate=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.r_frame_rate // "unknown")')
    color_range=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.color_range // "unknown")')
    duration=$(echo "$info_json" | jq -r '.format.duration // "0"')
    
    # Additional values needed for grain detection
    v_pix=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.pix_fmt // "unknown")')
    v_fps=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.avg_frame_rate // "0/1")')
    a_codec=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="audio")) | first // {} | (.codec_name // "")')
    a_profile=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="audio")) | first // {} | (.profile // "")')

    # Dolby Vision metadata (if present)
    dv_profile=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.side_data_list // []) | map(select(.side_data_type == "DOVI configuration record")) | first // {} | (.dv_profile // "none")')
    dv_bl_compat=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.side_data_list // []) | map(select(.side_data_type == "DOVI configuration record")) | first // {} | (.dv_bl_signal_compatibility_id // "none")')
    dv_el_present=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.side_data_list // []) | map(select(.side_data_type == "DOVI configuration record")) | first // {} | (.el_present_flag // "none")')
    dv_rpu_present=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first // {} | (.side_data_list // []) | map(select(.side_data_type == "DOVI configuration record")) | first // {} | (.rpu_present_flag // "none")')

    [[ -z "$dv_profile" || "$dv_profile" == "null" ]] && dv_profile="none"
    [[ -z "$dv_bl_compat" || "$dv_bl_compat" == "null" ]] && dv_bl_compat="none"
    [[ -z "$dv_el_present" || "$dv_el_present" == "null" ]] && dv_el_present="none"
    [[ -z "$dv_rpu_present" || "$dv_rpu_present" == "null" ]] && dv_rpu_present="none"
    
    # Format codec name once
    local format_upper
    format_upper=$(echo "$codec_name" | tr '[:lower:]' '[:upper:]')
    
    # Detect HDR type and Dolby Vision
    local hdr_type="none"
    local is_dolby_vision=false

    if [[ "$dv_profile" != "none" ]]; then
        hdr_type="dolby_vision"
        is_dolby_vision=true
    elif echo "$info_json" | grep -qiE "dolby[[:space:]]?vision|dvhe|dovi"; then
        hdr_type="dolby_vision"
        is_dolby_vision=true
    elif [[ "$codec_name" == "dvhe" || "$codec_name" == "dvh1" ]]; then
        hdr_type="dolby_vision"
        is_dolby_vision=true
    elif [[ "$color_transfer" == "smpte2084" ]]; then
        hdr_type="hdr10"
    elif [[ "$color_transfer" == "arib-std-b67" ]]; then
        hdr_type="hlg"
    elif [[ "$color_primaries" == "bt2020" ]]; then
        hdr_type="hdr"
    fi
    
    # Extract HDR10 mastering display and content light metadata if present
    local md_json cl_json
    md_json=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first | (.side_data_list // []) | map(select((.side_data_type // "") == "Mastering display metadata")) | first // empty')
    cl_json=$(echo "$info_json" | jq -r '(.streams // []) | map(select(.codec_type=="video")) | first | (.side_data_list // []) | map(select((.side_data_type // "") == "Content light level metadata")) | first // empty')

    # Build ffmpeg-friendly strings if available
    local MASTER_DISPLAY="" CONTENT_LIGHT=""
    if [[ -n "$md_json" && "$md_json" != "null" ]]; then
        # Expect float values like 0.3127 etc. Convert to integer units used by ffmpeg (x,y in 0.00002 units; luminance in 1/10000 nits)
        # Helper via awk for robust math without relying on bash floating point
        read -r r_x r_y g_x g_y b_x b_y wp_x wp_y max_lum min_lum < <(echo "$md_json" | jq -r '[.red_x,.red_y,.green_x,.green_y,.blue_x,.blue_y,.white_point_x,.white_point_y,.max_luminance,.min_luminance] | @tsv')
        if [[ -n "$r_x" && "$r_x" != "null" ]]; then
            # Convert chromaticities to 0..50000 integer domain and luminance to nits*10000
            eval "r_x_i=$(awk -v v=$r_x 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "r_y_i=$(awk -v v=$r_y 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "g_x_i=$(awk -v v=$g_x 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "g_y_i=$(awk -v v=$g_y 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "b_x_i=$(awk -v v=$b_x 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "b_y_i=$(awk -v v=$b_y 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "wp_x_i=$(awk -v v=$wp_x 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "wp_y_i=$(awk -v v=$wp_y 'BEGIN{printf "%d", (v*50000+0.5)}')"
            eval "max_lum_i=$(awk -v v=$max_lum 'BEGIN{printf "%d", (v*10000+0.5)}')"
            eval "min_lum_i=$(awk -v v=$min_lum 'BEGIN{printf "%d", (v*10000+0.5)}')"
            MASTER_DISPLAY=$(printf 'G(%d,%d)B(%d,%d)R(%d,%d)WP(%d,%d)L(%d,%d)' "$g_x_i" "$g_y_i" "$b_x_i" "$b_y_i" "$r_x_i" "$r_y_i" "$wp_x_i" "$wp_y_i" "$max_lum_i" "$min_lum_i")
        fi
    fi
    if [[ -n "$cl_json" && "$cl_json" != "null" ]]; then
        read -r max_cll max_fall < <(echo "$cl_json" | jq -r '[.max_content,.max_average] | @tsv')
        if [[ -n "$max_cll" && "$max_cll" != "null" && -n "$max_fall" && "$max_fall" != "null" ]]; then
            # ffmpeg expects integers here already in nits
            CONTENT_LIGHT=$(printf '%d,%d' "$max_cll" "$max_fall")
        fi
    fi

    # Return structured data - now with bonus grain detection info and HDR metadata
cat << EOF
CODEC_NAME='$codec_name'
WIDTH='$width'
HEIGHT='$height'
COLOR_TRANSFER='$color_transfer'
COLOR_SPACE='$color_space'
COLOR_PRIMARIES='$color_primaries'
COLOR_RANGE='$color_range'
FRAMERATE='$framerate'
DURATION='$duration'
FORMAT_UPPER='$format_upper'
HDR_TYPE='$hdr_type'
IS_DOLBY_VISION='$is_dolby_vision'
V_PIX='$v_pix'
V_FPS='$v_fps'
A_CODEC='$a_codec'
A_PROFILE='$a_profile'
MASTER_DISPLAY='$MASTER_DISPLAY'
CONTENT_LIGHT='$CONTENT_LIGHT'
DV_PROFILE='$dv_profile'
DV_BL_COMPATIBILITY_ID='$dv_bl_compat'
DV_EL_PRESENT='$dv_el_present'
DV_RPU_PRESENT='$dv_rpu_present'
EOF
}

# Format duration nicely (because life's too short for ugly timestamps)
format_duration() {
    local duration="$1"
    if [[ "$duration" != "0" && "$duration" != "unknown" && -n "$duration" ]]; then
        local total_seconds=${duration%.*}
        local hours=$((total_seconds / 3600))
        local minutes=$(( (total_seconds % 3600) / 60 ))
        local seconds=$((total_seconds % 60))
        printf "%02d:%02d:%02d" $hours $minutes $seconds
    else
        echo "Unknown"
    fi
}

# Film grain detection and classification (ML-based)
detect_film_grain() {
    local file="$1"
    local test_mode="${2:-false}"
    
    # Reset or the last film's dandruff gets everywhere
    svt_film_grain=0
    svt_params_extra=""

    # CRF targets (we only ever LOWER to these; we never raise a user's CRF)
    local CRF_ANIMATION="${crf_animation}"
    local CRF_FILM_PRESERVE="${crf_film}"
    local CRF_TV_DENOISE="${crf_tv}"
    # -------------------------------------------------------------------------

    log "Analysing content type and grain characteristics..." "33" true

    # Use the data we already have from get_comprehensive_video_info!
    local duration_s v_codec v_pix v_fps a_codec a_profile width height
    duration_s="$DURATION"
    v_codec="$CODEC_NAME" 
    v_pix="$V_PIX"
    v_fps="$V_FPS"
    a_codec="$A_CODEC"
    a_profile="$A_PROFILE"
    width="$WIDTH"
    height="$HEIGHT"

    # Quick sanity check
    local total_duration fps
    total_duration=$(awk -v d="$duration_s" 'BEGIN{ print int(d) }')
    if [[ -z "$total_duration" || "$total_duration" -lt 30 ]]; then
        log "Very short content or unknown duration; using safe defaults" "33"
        svt_film_grain=0
        log "Content analysis: short/unknown -> grain=$svt_film_grain" "32" true
        return
    fi
    fps="$(awk -v r="$v_fps" 'BEGIN{split(r,a,"/"); if(!a[2]){print 0; exit} printf("%.2f", a[1]/a[2])}')"

    # ========================================================================
    # MACHINE LEARNING CONTENT CLASSIFICATION - I trained this myself! (Sorry if it sucks)
    # ========================================================================

    local filename; filename=$(basename "$file")
    log "Analyzing: $filename" "33"

    # Path to the machine learning classifier executable
    local classifier_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/media_classifier"
    
    # Check if classifier exists
    if [[ ! -x "$classifier_path" ]]; then
        log "ERROR: ML classifier not found at $classifier_path" "31" true
        log "Grain detection was requested but classifier is missing!" "31" true
        log "Using AV1 defaults: no grain synthesis, standard encoding parameters" "31" true
        content_type="Unknown (using AV1 defaults)"
        confidence="N/A"
        base_grain=0  # AV1 default: no synthetic grain
        preservation_mode=false
        crf_target="28"  # Standard AV1 CRF default
    else
        # Run the machine learning classifier (suppress OpenCV warnings)
        local ml_prediction
        if ml_prediction=$("$classifier_path" "$file" 2>/dev/null); then
            log "ML Classification: $ml_prediction" "32"
            
            case "$ml_prediction" in
                "ANIMATION")
                    content_type="Animation"
                    confidence="High (ML)"
                    base_grain=0  # Heavy denoise, no synthetic grain
                    preservation_mode=false
                    crf_target="$CRF_ANIMATION"
                    ;;
                "FILM")
                    content_type="Film"
                    confidence="High (ML)"
                    base_grain=0  # Preserve original grain characteristics
                    preservation_mode=true
                    crf_target="$CRF_FILM_PRESERVE"
                    ;;
                "TV")
                    content_type="TV Show"
                    confidence="High (ML)"
                    base_grain=6  # Moderate synthetic grain after denoising
                    preservation_mode=false
                    crf_target="$CRF_TV_DENOISE"
                    ;;
                *)
                    log "Warning: Unknown ML prediction '$ml_prediction', using script defaults" "31"
                    log "Script defaults: CRF=${crf}, grain=0, preset=${preset}" "33"
                    content_type="Unknown"
                    confidence="Low"
                    base_grain=0
                    preservation_mode=false
                    crf_target="${crf}"
                    ;;
            esac
        else
            log "Warning: ML classifier failed, using script defaults" "31"
            log "Script defaults: CRF=${crf}, grain=0, preset=${preset}" "33"
            content_type="Unknown"
            confidence="Low"  
            base_grain=0
            preservation_mode=false
            crf_target="${crf}"
        fi
    fi

    log "Classification: $content_type ($confidence confidence)" "33"

    # ========================================================================
    # TEST MODE OUTPUT
    # ========================================================================
    
    if [[ "$test_mode" == true ]]; then
        printf "Content Type: %s\n" "$content_type"
        printf "Confidence: %s\n" "$confidence" 
        printf "Base Grain: %d\n" "$base_grain"
        printf "Preservation Mode: %s\n" "$preservation_mode"
        printf "Target CRF: %s\n" "$crf_target"
        printf "Classification Method: Machine Learning + Computer Vision\n"
        printf "File Info: %s %dx%d %s %.2ffps audio:%s\n" "$v_codec" "$width" "$height" "$v_pix" "$(echo "$fps" | bc -l 2>/dev/null || echo "$fps")" "$a_codec"
        printf "Classifier Path: %s\n" "$classifier_path"
        return 0
    fi

    # ========================================================================
    # ENCODING PARAMETER OPTIMIZATION
    # ========================================================================

    # CRF optimization based on content type
    if [[ "${crf:-30}" =~ ^[0-9]+$ && "$crf" -gt "$crf_target" ]]; then
        log "Optimizing CRF for $content_type: $crf → $crf_target" "33" true
        crf="$crf_target"
    fi

    # Preset scaling for different content types
    local final_grain="$base_grain"
    if [[ -n "${preset:-}" && "${preset}" =~ ^[0-9]+$ ]]; then
        case "$content_type" in
            "Animation"|"Probable Animation")
                # Animation can use faster presets without quality loss
                [[ "$preset" -lt "$animation_preset" ]] && { log "Animation: increasing preset to $animation_preset for efficiency" "33" true; preset="$animation_preset"; }
                final_grain=0
                ;;
            "Film"|"Probable Film")
                # Film needs slower presets for grain preservation
                [[ "$preset" -gt "$film_preset" ]] && { log "Film: reducing preset to $film_preset for grain preservation" "33" true; preset="$film_preset"; }
                final_grain=$((base_grain * 100 / 100))  # Full grain for films
                ;;
            "TV Show"|"Probable TV")
                # TV shows balance speed vs quality - adjust preset if needed
                [[ "$preset" -ne "$tv_preset" ]] && { log "TV: adjusting preset to $tv_preset for optimal quality/speed balance" "33" true; preset="$tv_preset"; }
                if [[ "$preset" -ge 8 ]]; then
                    final_grain=$((base_grain * 70 / 100))
                elif [[ "$preset" -eq 7 ]]; then
                    final_grain=$((base_grain * 85 / 100))
                fi
                ;;
        esac
    fi

    # Clamp grain values
    [[ $final_grain -lt 0 ]] && final_grain=0
    [[ $final_grain -gt 50 ]] && final_grain=50
    svt_film_grain="$final_grain"

    # ========================================================================
    # SVT-AV1 PARAMETER OPTIMISATION
    # ========================================================================

    svt_params_extra=""
    _add_if_supported() {
        local k="$1" v="$2"
        local ff="${ffmpeg_path:-ffmpeg}"

        if "$ff" -hide_banner -h encoder=libsvtav1 2>/dev/null | grep -qE "(^|[[:space:]])${k}="; then
            svt_params_extra+=":${k}=${v}"; return
        fi

        if "$ff" -v error -nostdin -f lavfi -i color=size=64x64:rate=1:duration=1 \
                -frames:v 1 -c:v libsvtav1 -svtav1-params "${k}=${v}" -f null - >/dev/null 2>&1; then
            svt_params_extra+=":${k}=${v}"; return
        fi
    }

    # Content-specific parameter optimization
    case "$content_type" in
        "Animation"|"Probable Animation")
            # Animation: Enable all denoising, disable grain synthesis
            _add_if_supported "film-grain-denoise" "1"
            _add_if_supported "enable-restoration" "1"
            _add_if_supported "enable-cdef" "1"
            _add_if_supported "enable-wiener" "1"
            _add_if_supported "enable-sgr" "1"
            svt_aq_mode=2  # Standard AQ for clean content
            log "Animation mode: enabling all denoising filters" "33" true
            ;;
        
        "Film"|"Probable Film")
            # Film: Disable all filtering to preserve authentic grain
            _add_if_supported "film-grain-denoise" "0"
            _add_if_supported "enable-tf" "0"
            _add_if_supported "enable-restoration" "0"
            _add_if_supported "enable-cdef" "0" 
            _add_if_supported "enable-dlf" "0"
            _add_if_supported "enable-wiener" "0"
            _add_if_supported "enable-sgr" "0"
            _add_if_supported "enable-intra-edge-filter" "0"
            if [[ $svt_film_grain -gt 0 ]]; then
                svt_aq_mode=3  # Aggressive AQ for textured content when keeping grain
            else
                svt_aq_mode=2
            fi
            svt_sharpness=2  # Preserve fine details
            log "Film preservation mode: disabling all filtering" "33" true
            ;;

        "TV Show"|"Probable TV")
            # TV: Moderate denoising + synthetic grain
            _add_if_supported "film-grain-denoise" "1"
            if [[ $svt_film_grain -gt 0 ]]; then
                svt_aq_mode=3
            else
                svt_aq_mode=2
            fi
            log "TV show mode: moderate denoising with synthetic grain" "33" true
            ;;
    esac

    # Tune parameter compatibility
    if [[ "$svt_tune" -eq 0 ]]; then
        svt_fast_decode=1
        svt_tile_columns=1
        log "PSNR tuning compatibility adjustments" "33" true
    else
        svt_tile_columns=1
        log "VMAF tuning mode" "33" true
    fi

    export svt_params_extra

    log "Content analysis: $content_type (confidence: $confidence) -> grain=$svt_film_grain" "32" true

    # Verbose output
    if [[ "${verbose:-false}" == true ]]; then
        log "ML Classification: $content_type ($confidence confidence)" "33"
        log "Encoding mode: preservation=$preservation_mode crf=$crf preset=$preset grain=$svt_film_grain" "33"
        log "SVT parameters: ${svt_params_extra#:}" "33"
    fi
}

# ============================================================================
# FILE MANAGEMENT FUNCTIONS
# ============================================================================

# Safe file size in bytes (handles missing/unreadable files quietly)
safe_stat_size() {
    local path="$1"
    if [[ -e "$path" ]]; then
        stat -c %s -- "$path" 2>/dev/null || return 1
    else
        return 1
    fi
}

# Get file size (human). Returns "Unknown" on failure.
get_file_size() {
    local _sz
    if _sz=$(safe_stat_size "$1"); then
        numfmt --to=iec --format='%.2f' "$_sz" 2>/dev/null
    else
        echo "Unknown"
    fi
}

# Ensure unique temp filename
ensure_temp_filename() {
    local base="$1"
    local count=0
    local result="$base"
    
    while [[ -e "$result" ]]; do
        count=$((count + 1))
        result="${base%.mkv}_${count}.mkv"
    done
    
    echo "$result"
}

# Transform filename to clean AV1 version
transform_filename() {
    local filename="$1"
    local directory basefilename_no_ext
    directory=$(dirname "$filename")
    basefilename_no_ext="${filename%.*}"
    basefilename_no_ext=$(basename "$basefilename_no_ext")
    
    local cleanfilename="$basefilename_no_ext"
    
    # Swap video codecs for AV1 - no fancy punctuation logic, just brute force
    cleanfilename=$(echo "$cleanfilename" | sed -E '
        s/\b(x264|x265|h264|h265|hevc|xvid|divx|mpeg2|mpeg4|vp9|avc)\b/AV1/Ig;
        s/\b(264|265)\b/AV1/Ig;
    ')
    
    # Swap audio codecs for OPUS
    cleanfilename=$(echo "$cleanfilename" | sed -E '
        s/\b(aac|mp3|ac3|dts|flac|ogg|vorbis|opus)\b/OPUS/Ig;
    ')
    
    # Handle resolution changes if we're resizing (optional carnage)
    if [[ $resize == true ]]; then
        local res_pat
        if (( resize_target_height <= 720 )); then
            # When targeting 720p, also down-tag 1080p labels
            res_pat='(4k|2160p|2k|1440p|uhd|1080p)'
        else
            res_pat='(4k|2160p|2k|1440p|uhd)'
        fi
        cleanfilename=$(echo "$cleanfilename" | sed -E "s/\\b${res_pat}\\b/${resize_target_height}p/Ig")
    fi
    
    # If no video codec was found, add AV1 - because we're encoding to AV1, obviously
    if [[ ! "$cleanfilename" =~ AV1 ]]; then
        cleanfilename+=" AV1"
    fi
    
    # Slap on the .mkv extension - the container that doesn't mess about
    echo "$directory/$cleanfilename.mkv"
}

# Move completed file safely
move_completed_file() {
    local temp_file="$1"
    local final_destination="$2"
    local destination_dir
    destination_dir=$(dirname "$final_destination")

    mkdir -p "$destination_dir"

    if [[ ! -f "$temp_file" ]]; then
        log "Error: Source file does not exist: $temp_file" "31" true
        return 1
    fi

    # Check space
    local file_size dest_free
    file_size=$(safe_stat_size "$temp_file") || {
        log "Error: Could not determine file size of $temp_file" "31" true
        return 1
    }
    dest_free=$(df -P "$destination_dir" | awk 'NR==2 {print $4 * 1024}') || {
        log "Error: Could not determine free space in destination" "31" true
        return 1
    }

    if [[ $file_size -gt $dest_free ]]; then
        log "Error: Not enough space in destination directory" "31" true
        return 1
    fi

    if ! mv "$temp_file" "$final_destination"; then
        log "Error: Failed to move file to destination" "31" true
        return 1
    fi

    log "Successfully moved file to: $final_destination" "32"
    return 0
}

# ============================================================================
# AUDIO AND SUBTITLE PROCESSING - I need to spend more time on this!
# ============================================================================

# Process Audio Channels
process_audio() {
    local file="$1"
    local -n audio_options_ref="$2"
    local audio_streams
    local ffprobe_exit_code
    audio_streams=$(ffprobe -v error -select_streams a \
        -show_entries stream=index:stream_tags=language:stream=channels \
        -of csv=p=0 "$file" 2>/dev/null)
    ffprobe_exit_code=$?
    
    # Check if ffprobe failed
    if [[ $ffprobe_exit_code -ne 0 ]]; then
        log "ERROR: ffprobe failed to analyze audio streams (exit code: $ffprobe_exit_code)" "31" true
        log "This could indicate file corruption or unsupported format" "31" true
        notify "Audio Processing Error" "Failed to analyze audio in $(basename "$file"). File may be corrupted."
        printf '\a'  # Terminal bell
        return 1
    fi

    audio_options_ref=()
    local output_audio_index=0

    # Check if any audio streams were detected
    if [[ -z "$audio_streams" ]]; then
        log "WARNING: No audio streams detected in file. Audio will be excluded from output." "31" true
        notify "Audio Warning" "No audio streams detected in $(basename "$file"). Output will have no audio."
        printf '\a'  # Terminal bell
        return 0
    fi

    local IFS=$'\n'
    for stream in $audio_streams; do
        IFS=',' read -r index channels language <<< "$stream"
        
        # Validate that we got proper values
        if [[ -z "$index" || ! "$index" =~ ^[0-9]+$ ]]; then
            log "WARNING: Invalid audio stream index '$index' for stream: $stream" "31" true
            continue
        fi
        
        log "Processing audio stream $index: ${channels:-unknown} channels, language: ${language:-unknown}" "33"
        audio_options_ref+=("-map" "0:$index")

        local user_bitrate="${audio_bitrate_override:-}"
        
        # Validate and set channels
        if [[ -z "$channels" || ! "$channels" =~ ^[0-9]+$ || $channels -eq 0 ]]; then
            log "WARNING: Invalid or missing channel count '$channels' for stream $index, assuming stereo" "31" true
            channels=2
        fi
        
        local target_channels=$channels
        local max_bitrate
        local bitrate

        # Set sensible defaults based on channel count
        if [[ $channels -eq 1 ]]; then
            bitrate="64k"
            max_bitrate=256000
        elif [[ $channels -eq 2 ]]; then
            bitrate="128k"
            max_bitrate=512000
        else
            # libopus limit is 1536k for anything above stereo
            bitrate="384k"
            max_bitrate=1536000
        fi

        # If the user has set a bitrate, check and clamp if necessary
        if [[ -n "$user_bitrate" ]]; then
            local requested_bitrate_bps="${user_bitrate%k}000"
            # Stereo downmix: max is 512k no matter what
            if [[ $stereo_downmix == true && $channels -gt 2 ]]; then
                target_channels=2
                max_bitrate=512000
                bitrate="$user_bitrate"
                if (( requested_bitrate_bps > max_bitrate )); then
                    bitrate="512k"
                    log "Requested bitrate '$user_bitrate' for stereo downmix exceeds 512k limit. Capped at 512k." "33" true
                fi
            else
                bitrate="$user_bitrate"
                if (( requested_bitrate_bps > max_bitrate )); then
                    local max_k=$((max_bitrate / 1000))
                    bitrate="${max_k}k"
                    log "Requested bitrate '$user_bitrate' for ${channels}-channel audio exceeds codec limits. Capped at ${max_k}k." "33" true
                fi
            fi
        fi

        # Use pre-determined audio codec from startup check
        local audio_codec="$preferred_audio_codec"
        if [[ $stereo_downmix == true && $channels -gt 2 ]]; then
            audio_options_ref+=("-ac:a:$output_audio_index" "$target_channels" \
                                "-c:a:$output_audio_index" "$audio_codec" \
                                "-b:a:$output_audio_index" "$bitrate" \
                                "-af:a:$output_audio_index" "pan=stereo|FL<FL+0.707*FC+0.707*BL|FR<FR+0.707*FC+0.707*BR")
        else
            audio_options_ref+=("-ac:a:$output_audio_index" "$target_channels" \
                                "-c:a:$output_audio_index" "$audio_codec" \
                                "-b:a:$output_audio_index" "$bitrate")
        fi

        if [[ -n "$language" && "$language" != "und" ]]; then
            audio_options_ref+=("-metadata:s:a:$output_audio_index" "language=$language")
        fi

        output_audio_index=$((output_audio_index + 1))
    done

    log "Audio streams processed: $output_audio_index" "33"
    
    # Final validation - make sure we have audio mapping
    if [[ $output_audio_index -eq 0 ]]; then
        log "WARNING: No valid audio streams were processed. Output will have no audio." "31" true
    else
        log "Audio encoding configured: ${#audio_options_ref[@]} FFmpeg parameters" "32"
    fi
}

# Validate if a subtitle codec is supported in Matroska container
validate_subtitle_codec() {
    local codec="$1"
    local file="$2"
    local stream_index="$3"
    
    # List of codecs known to work well in MKV containers
    case "$codec" in
        "subrip"|"ass"|"ssa"|"webvtt"|"srt")
            echo "copy"  # Text-based subtitles - safe to copy
            ;;
        "mov_text")
            # mov_text from MP4 often has compatibility issues with MKV - convert to SRT
            echo "srt"  # Convert mov_text to SRT for better MKV compatibility
            ;;
        "hdmv_pgs_subtitle"|"pgssub")
            echo "copy"  # PGS subtitles - supported in MKV
            ;;
        "dvd_subtitle"|"dvdsub")
            echo "skip"  # DVD subtitles are problematic in MKV
            ;;
        "")
            # Empty codec name - probe deeper
            log "Warning: Empty subtitle codec name for stream $stream_index, skipping" "33"
            echo "skip"
            ;;
        *)
            # Unknown codec - try to identify by codec ID or skip to be safe
            log "Warning: Unknown subtitle codec '$codec' for stream $stream_index, skipping to prevent encoding failure" "33"
            echo "skip"
            ;;
    esac
}

# Check subtitle formats and return appropriate ffmpeg flags based on preferences
check_subtitle_formats() {
    local file="$1"
    local info
    info=$(ffprobe -v error -select_streams s \
        -show_entries stream=index,codec_name,disposition:stream_tags=language,title \
        -of json "$file" 2>/dev/null)
    
    if [[ -z "$info" || "$info" == "{}" ]]; then
        echo ""
        return
    fi

    local preferred_text_subs=()
    local preferred_pgs_subs=()
    local other_preferred_subs=()
    local forced_subs=()

    while IFS= read -r stream; do
        local index lang codec title forced
        index=$(echo "$stream" | jq -r '.index')
        lang=$(echo "$stream" | jq -r '.tags.language // "und"')
        codec=$(echo "$stream" | jq -r '.codec_name // ""')
        title=$(echo "$stream" | jq -r '.tags.title // ""')
        forced=$(echo "$stream" | jq -r '.disposition.forced // 0')
        
        # Check for forced/SDH indicators in title
        local is_forced=false
        if [[ $forced -eq 1 || "$title" =~ [Ff]orced|SDH|CC ]]; then
            is_forced=true
        fi
        
        # Match preferred language (and alternative codes like "enm" for English)
        local lang_match=false
        if [[ "$lang" == "$preferred_subtitle_language" ]]; then
            lang_match=true
        elif [[ "$preferred_subtitle_language" == "eng" && "$lang" == "enm" ]]; then
            lang_match=true  # English with honorifics/alternative
        fi
        
        if [[ $lang_match == true ]]; then
            # If forced_subtitles_only is true, only include forced subtitles
            if [[ $forced_subtitles_only == true && $is_forced == false ]]; then
                continue
            fi
            
            # Validate codec compatibility before adding to any category
            local codec_action
            codec_action=$(validate_subtitle_codec "$codec" "$file" "$index")
            
            if [[ "$codec_action" == "skip" ]]; then
                continue  # Skip unsupported codecs
            fi
            
            # Categorize forced subtitles separately for priority
            if [[ $is_forced == true ]]; then
                forced_subs+=("$index")
            elif [[ "$codec" == "subrip" || "$codec" == "mov_text" || "$codec" == "ass" || "$codec" == "ssa" ]]; then
                preferred_text_subs+=("$index")
            elif [[ "$codec" == "hdmv_pgs_subtitle" || "$codec" == "pgssub" ]]; then
                preferred_pgs_subs+=("$index")
            else
                # This shouldn't happen now due to validation, but keep as fallback
                other_preferred_subs+=("$index")
            fi
        fi
    done < <(echo "$info" | jq -c '.streams[]')

    local map_options=()

    # Priority: forced subs > text subs > PGS > other formats
    # Always include forced subtitles first
    for idx in "${forced_subs[@]:0:1}"; do
        map_options+=("-map" "0:$idx" "-disposition:s:$((${#map_options[@]}/2))" "forced")
    done

    # Include regular subtitles if: forced_subtitles_only=false OR no forced subs were found
    if [[ $forced_subtitles_only == false ]] || [[ ${#forced_subs[@]} -eq 0 ]]; then
        # Add text subs (limit to 2 total including any forced)
        local remaining=$((2 - ${#map_options[@]}/2))
        for idx in "${preferred_text_subs[@]:0:$remaining}"; do
            map_options+=("-map" "0:$idx")
        done

        # If no text subs, try PGS
        if [[ ${#map_options[@]} -eq 0 && ${#preferred_pgs_subs[@]} -gt 0 ]]; then
            for idx in "${preferred_pgs_subs[@]:0:2}"; do
                map_options+=("-map" "0:$idx")
            done
        fi

        # If still nothing, grab other subtitle formats
        if [[ ${#map_options[@]} -eq 0 && ${#other_preferred_subs[@]} -gt 0 ]]; then
            for idx in "${other_preferred_subs[@]:0:2}"; do
                map_options+=("-map" "0:$idx")
            done
        fi
    fi

    if [[ ${#map_options[@]} -gt 0 ]]; then
        # Determine appropriate codec based on what we're processing
        local subtitle_codec="copy"
        local has_mov_text=false
        
        # Check if we have any mov_text streams that need conversion
        for ((i=0; i<${#map_options[@]}; i+=2)); do
            if [[ "${map_options[i]}" == "-map" ]]; then
                local stream_spec="${map_options[i+1]}"
                local stream_index="${stream_spec#0:}"
                local codec_info
                codec_info=$(echo "$info" | jq -r --argjson idx "$stream_index" '.streams[] | select(.index == $idx) | .codec_name // ""')
                if [[ "$codec_info" == "mov_text" ]]; then
                    has_mov_text=true
                    break
                fi
            fi
        done
        
        # Set appropriate codec
        if [[ $has_mov_text == true ]]; then
            map_options+=("-c:s" "srt")
            log "Converting mov_text subtitles to SRT for MKV compatibility" "32"
        else
            map_options+=("-c:s" "copy")
        fi
        
        # Log what we're including
        local sub_count=$((${#map_options[@]} / 2 - 1))  # -1 for the codec option
        if [[ ${#forced_subs[@]} -gt 0 ]]; then
            log "Including forced $preferred_subtitle_language subtitles" "32"
        fi
        if [[ $forced_subtitles_only == false && $sub_count -gt ${#forced_subs[@]} ]]; then
            log "Including $preferred_subtitle_language subtitles (${sub_count} tracks)" "32"
        fi
    else
        if [[ $forced_subtitles_only == true ]]; then
            log "No forced $preferred_subtitle_language subtitles found" "33"
        else
            log "No $preferred_subtitle_language subtitles found" "33"
        fi
    fi

    echo "${map_options[*]}"
}

# Set preferred language as default audio track
set_default_audio_track() {
    local file="$1"

    local json_output
    json_output=$(mkvmerge --identification-format json --identify "$file")

    local audio_languages=()
    mapfile -t audio_languages < <(echo "$json_output" | jq -r '
        [.tracks[] | select(.type == "audio") | .properties.language // "und"] | .[]
    ')

    local preferred_track_seq="" und_track_seq="" first_track_seq=""
    local seq_number=1

    for lang in "${audio_languages[@]}"; do
        if [[ -z "$first_track_seq" ]]; then
            first_track_seq="$seq_number"
        fi

        if [[ "$lang" == "$preferred_audio_language" ]]; then
            preferred_track_seq="$seq_number"
            break
        elif [[ "$lang" == "und" ]] && [[ -z "$und_track_seq" ]]; then
            und_track_seq="$seq_number"
        fi

        seq_number=$((seq_number + 1))
    done

    local default_track_seq=""
    if [[ -n "$preferred_track_seq" ]]; then
        default_track_seq="$preferred_track_seq"
    elif [[ -n "$und_track_seq" ]]; then
        default_track_seq="$und_track_seq"
    else
        default_track_seq="$first_track_seq"
    fi

    if [[ -n "$default_track_seq" ]]; then
        local mkvpropedit_cmd=(mkvpropedit "$file")

        local reset_seq_number=1
        for _ in "${audio_languages[@]}"; do
            mkvpropedit_cmd+=(--edit track:a"$reset_seq_number" --set flag-default=0)
            reset_seq_number=$((reset_seq_number + 1))
        done

        mkvpropedit_cmd+=(--edit track:a"$default_track_seq" --set flag-default=1)

        if "${mkvpropedit_cmd[@]}"; then
            local track_info="track:a$default_track_seq"
            if [[ -n "$preferred_track_seq" ]]; then
                track_info="$track_info ($preferred_audio_language)"
            elif [[ -n "$und_track_seq" ]]; then
                track_info="$track_info (undefined language)"
            else
                track_info="$track_info (first track)"
            fi
            log "Set default audio track to $track_info" "32"
        else
            log "Failed to set default audio track" "31"
        fi
    fi
}

# ============================================================================
# FILE DISCOVERY AND FILTERING
# ============================================================================

# Display progress during file finding
display_find_progress() {
    local total=$1
    local current=$2
    local filename=${3:-}
    
    if [[ -z "$filename" ]]; then
        printf "\rScanning: [%d/%d]" "$current" "$total"
    else
        local shortname
        shortname=$(basename "$filename")
        if [[ ${#shortname} -gt 50 ]]; then
            shortname="${shortname:0:47}..."
        fi
        printf "\rScanning: [%d/%d] %s" "$current" "$total" "$shortname"
    fi
}

# Find all video files
generate_video_list() {
    log "Initiating file system scan..." "34"
    log "Searching in directory: $directory" "34"
    log "Minimum file size: $size" "34"

    videolist=()
    local file_count=0
    local found_files=()
    local found_any_files=false
    
    # Count total files first
    local total_files
    total_files=$(find "$directory" -type f -size "+$size" \
        \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.webm" \
           -o -iname "*.mpg" -o -iname "*.mpv" -o -iname "*.m2ts" -o -iname "*.ts" \
           -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.mxf" -o -iname "*.wmv" \
           -o -iname "*.flv" -o -iname "*.3gp" -o -iname "*.asf" -o -iname "*.vob" \
           -o -iname "*.rm" -o -iname "*.rmvb" -o -iname "*.f4v" -o -iname "*.divx" \
           -o -iname "*.xvid" \) \
        ! -path "*/extras/*" ! -path "*/samples/*" -printf '.' | wc -c)

    display_find_progress "$total_files" 0

    # Collect files with progress
    while IFS= read -r -d '' file; do
        found_any_files=true
        videolist+=("$file")
        found_files+=("$file")
        file_count=$((file_count + 1))
        
        display_find_progress "$total_files" "$file_count" "$file"
        
    done < <(find "$directory" -type f -size "+$size" \
        \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.webm" \
           -o -iname "*.mpg" -o -iname "*.mpv" -o -iname "*.m2ts" -o -iname "*.ts" \
           -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.mxf" -o -iname "*.wmv" \
           -o -iname "*.flv" -o -iname "*.3gp" -o -iname "*.asf" -o -iname "*.vob" \
           -o -iname "*.rm" -o -iname "*.rmvb" -o -iname "*.f4v" -o -iname "*.divx" \
           -o -iname "*.xvid" \) \
        ! -path "*/extras/*" ! -path "*/samples/*" -print0)

    echo

    if ! $found_any_files; then
        echo "No files found in $directory matching the criteria."
        exit 0
    else
        log "Found ${#videolist[@]} files eligible for conversion." "32"
        
        echo "Found files:"
        printf '%s\n' "${found_files[@]}" | sed 's:^.*/::' | sort
    fi

    # Apply ignore filters if enabled
    if [[ $ignore == true ]]; then
        log "Applying ignore filters for CAM, WORKPRINT, and TELESYNC files..." "33"
        local filtered_videolist=()
        for file in "${videolist[@]}"; do
            local basename
            basename=$(basename "$file")
            if [[ $basename =~ CAM|WORKPRINT|TELESYNC ]]; then
                log "Ignoring file due to filter: $file" "31"
            else
                filtered_videolist+=("$file")
            fi
        done
        videolist=("${filtered_videolist[@]}")
        log "After applying ignore filters, ${#videolist[@]} files remain." "32"
    fi

    if [[ ${#videolist[@]} -eq 0 ]]; then
        echo "No files remain after applying ignore filters."
        exit 0
    fi
}

# Check if file should be converted
should_convert() {
    local file="$1"
    local video_info
    
    if ! video_info=$(get_comprehensive_video_info "$file"); then
        return 1  # Skip corrupt files
    fi
    
    # shellcheck disable=SC2030
    eval "$video_info"
    
    # Dolby Vision handling
    if [[ "$HDR_TYPE" == "dolby_vision" || "$IS_DOLBY_VISION" == "true" ]]; then
        local dv_profile_value="${DV_PROFILE:-none}"
        local dv_bl_compat="${DV_BL_COMPATIBILITY_ID:-none}"

        if [[ "$skip_dolby_vision" == true ]]; then
            [[ "$verbose" == true ]] && log "Skipping Dolby Vision file (disabled via config): $file" "33"
            return 1
        fi

        # Require a known, HDR10-compatible Dolby Vision profile (7/8)
        if [[ "$dv_profile_value" != "7" && "$dv_profile_value" != "8" ]]; then
            [[ "$verbose" == true ]] && log "Skipping unsupported Dolby Vision profile ($dv_profile_value): $file" "33"
            return 1
        fi

        if [[ "$dv_bl_compat" == "0" || "$dv_bl_compat" == "none" ]]; then
            [[ "$verbose" == true ]] && log "Skipping Dolby Vision file without HDR10-compatible base layer: $file" "33"
            return 1
        fi
    fi
    
    # Decision logic
    if [[ "$force_reencode" == true ]]; then
        echo "$file"
        return
    fi

    if [[ "$av1" == true ]]; then
        if [[ "$FORMAT_UPPER" != "AV1" ]]; then
            echo "$file"
        elif [[ "$verbose" == true ]]; then
            log "Skipping already AV1 encoded file: $file" "33"
        fi
    else
        if [[ "$FORMAT_UPPER" != "HEVC" && "$FORMAT_UPPER" != "AV1" ]]; then
            echo "$file"
        elif [[ "$verbose" == true ]]; then
            log "Skipping file with format $FORMAT_UPPER: $file" "33"
        fi
    fi
}

# Export for parallel processing
export -f should_convert get_comprehensive_video_info
export av1 force_reencode verbose skip_dolby_vision
export -f log

# Filter video list using parallel processing - massive speed enhancement
filter_video_list() {
    log "Filtering video list based on format and encoding options..." "34"

    mapfile -t filtered_videolist < <(printf '%s\0' "${videolist[@]}" | \
        parallel -0 -j "$(nproc)" should_convert {})

    if [[ ${#filtered_videolist[@]} -eq 0 ]]; then
        log "No files to convert after filtering." "31"
        return 1
    fi

    printf '%s\n' "${filtered_videolist[@]}"
}

# ============================================================================
# ARGUMENT PARSING AND VALIDATION
# ============================================================================

parse_arguments() {
    local show_config=false
    local generate_config=false
    local config_output_file="av1conv.conf.sample"  # Default filename
    
    # First pass: parse all arguments including the special ones
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --generate-config)
                generate_config=true
                # Check if next argument exists and isn't another option
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    config_output_file="$2"
                    shift 2
                else
                    # No filename provided, use default
                    config_output_file="av1conv.conf.sample"
                    shift
                fi
                ;;
            --show-config)
                show_config=true
                shift
                ;;
            --config)
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --config requires a file path" >&2
                    exit 1
                fi
                export AV1CONV_CONFIG="$2"
                shift 2
                ;;
            -d|--dir) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -d/--dir requires a directory path" >&2
                    exit 1
                fi
                directory="$2"; shift 2 ;;
            -1|--av1) av1=true; shift ;;
            -f|--force) force=true; shift ;;
            -F|--force-reencode) force_reencode=true; shift ;;
            -h|--help) display_help; exit 0 ;;
            -v|--verbose) verbose=true; shift ;;
            -c|--crf) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -c/--crf requires a value" >&2
                    exit 1
                fi
                crf="$2"; shift 2 ;;
            -p|--preset) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -p/--preset requires a value" >&2
                    exit 1
                fi
                preset="$2"; shift 2 ;;
            -J|--parallel)
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -J/--parallel requires a value" >&2
                    exit 1
                fi
                max_parallel_jobs="$2"; shift 2 ;;
            -g|--gop) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -g/--gop requires a value" >&2
                    exit 1
                fi
                gop="$2"; shift 2 ;;
            -i|--ignore) ignore=true; shift ;;
            -l|--lazy) lazy=true; shift ;;
            -s|--size) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -s/--size requires a value" >&2
                    exit 1
                fi
                size="$2"; shift 2 ;;
            -r|--remove) remove_input_file=true; shift ;;
            -R|--resize-1080p) resize=true; resize_target_height=1080; shift ;;
            --resize-720p) resize=true; resize_target_height=720; shift ;;
            --allow-larger) allow_larger_files=true; shift ;;
            --stereo) stereo_downmix=true; shift ;;
            -ab|--audiobitrate)
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: -ab/--audiobitrate requires a value" >&2
                    exit 1
                fi
                if [[ "$2" =~ ^[0-9]+k$ ]]; then
                    audio_bitrate_override="$2"
                else
                    echo "Error: Audio bitrate must end with 'k' (e.g., 128k)" >&2
                    exit 1
                fi
                shift 2
                ;;
            --svt-tune) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-tune requires a value" >&2
                    exit 1
                fi
                svt_tune="$2"; shift 2 ;;
            --svt-overlays) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-overlays requires a value" >&2
                    exit 1
                fi
                svt_enable_overlays="$2"; shift 2 ;;
            --svt-fast-decode) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-fast-decode requires a value" >&2
                    exit 1
                fi
                svt_fast_decode="$2"; shift 2 ;;
            --svt-lookahead) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-lookahead requires a value" >&2
                    exit 1
                fi
                svt_lookahead="$2"; shift 2 ;;
            --svt-enable-qm) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-enable-qm requires a value" >&2
                    exit 1
                fi
                svt_enable_qm="$2"; shift 2 ;;
            --svt-qm-min) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-qm-min requires a value" >&2
                    exit 1
                fi
                svt_qm_min="$2"; shift 2 ;;
            --svt-qm-max) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-qm-max requires a value" >&2
                    exit 1
                fi
                svt_qm_max="$2"; shift 2 ;;
            --svt-tile-columns) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-tile-columns requires a value" >&2
                    exit 1
                fi
                svt_tile_columns="$2"; shift 2 ;;
            --svt-film-grain) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --svt-film-grain requires a value" >&2
                    exit 1
                fi
                svt_film_grain="$2"; shift 2 ;;
            --detect-grain) detect_grain=true; shift ;;
            --no-detect-grain) detect_grain=false; shift ;;
            --detect-grain-test)
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --detect-grain-test requires a file path" >&2
                    exit 1
                fi
                detect_grain_test_file="$2"
                detect_grain_test=true
                shift 2 ;;
            --temp-dir) 
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    echo "Error: --temp-dir requires a directory path" >&2
                    exit 1
                fi
                temp_root="$2"; shift 2 ;;
            --keep-temp) cleanup_on_exit=false; shift ;;
            --) shift; break ;;
            -*) echo "Unknown option: $1" >&2; display_help; exit 1 ;;
            *) break ;;
        esac
    done
    
    # Second pass: handle special commands AFTER all arguments are processed
    if [[ $generate_config == true ]]; then
        generate_sample_config "$config_output_file"
        exit 0
    fi
    
    if [[ $show_config == true ]]; then
        # Now all CLI overrides have been applied, so show the final config
        display_config true
        exit 0
    fi
    
    if [[ $detect_grain_test == true ]]; then
        # Test grain detection on a single file
        if [[ ! -f "$detect_grain_test_file" ]]; then
            echo "Error: File not found: $detect_grain_test_file" >&2
            exit 1
        fi
        
        echo "Testing grain detection on: $detect_grain_test_file"
        echo "=============================================="
        
        # Get video info first (required by detect_film_grain)
        if ! video_info=$(get_comprehensive_video_info "$detect_grain_test_file"); then
            echo "Error: Unable to analyze video file" >&2
            exit 1
        fi
        
        # Source the video info variables
        eval "$video_info"
        
        # Run grain detection in test mode
        detect_film_grain "$detect_grain_test_file" true
        exit 0
    fi
}


# ============================================================================
# ENCODING FUNCTIONS
# ============================================================================

# Parallel job management functions
start_parallel_display() {
    local log_dir="$1"
    
    if [[ $max_parallel_jobs -gt 1 ]]; then
        # Create log directory
        mkdir -p "$log_dir"
        # Print header once and reserve panel space (header + N blank lines)
        printf "Parallel Progress:\n"
        for ((i=1; i<=max_parallel_jobs; i++)); do printf "\n"; done
        # Save cursor position at end of panel (anchor for redraws)
        printf "\033[s"

        # Background refresher: redraw panel in place
        (
            while true; do
                # If a suspend flag exists, skip drawing to avoid interleaving
                if [[ -f "$log_dir/.panel_suspend" ]]; then
                    sleep 0.1
                    continue
                fi
                # Restore to end-of-panel anchor, then jump to header line
                printf "\033[u\033[%dA" $((max_parallel_jobs + 1))
                # Dynamic header with queue stats and savings so far
                local qs="$log_dir/queue_status"
                local TOTAL=0 STARTED=0 PROCESSED=0 SKIPPED=0 ACTIVE=0
                if [[ -f "$qs" ]]; then
                    TOTAL=$(grep -m1 '^TOTAL=' "$qs" 2>/dev/null | cut -d= -f2); TOTAL=${TOTAL:-0}
                    STARTED=$(grep -m1 '^STARTED=' "$qs" 2>/dev/null | cut -d= -f2); STARTED=${STARTED:-0}
                    PROCESSED=$(grep -m1 '^PROCESSED=' "$qs" 2>/dev/null | cut -d= -f2); PROCESSED=${PROCESSED:-0}
                    SKIPPED=$(grep -m1 '^SKIPPED=' "$qs" 2>/dev/null | cut -d= -f2); SKIPPED=${SKIPPED:-0}
                    ACTIVE=$(grep -m1 '^ACTIVE=' "$qs" 2>/dev/null | cut -d= -f2); ACTIVE=${ACTIVE:-0}
                    NEXT=$(grep -m1 '^NEXT=' "$qs" 2>/dev/null | cut -d= -f2-); NEXT=${NEXT:-}
                fi
                local DONE=$((PROCESSED + SKIPPED))
                local PENDING=$((TOTAL - STARTED)); if (( PENDING < 0 )); then PENDING=0; fi
                # Compute savings so far by summing lines (bytes) in savings file
                local savings_file="$log_dir/savings.lines"
                local SAVED_BYTES=0 SAVED_DISPLAY="0.00" KEPT=0
                if [[ -f "$savings_file" ]]; then
                    SAVED_BYTES=$(awk '{s+=$1} END{printf "%d", s}' "$savings_file" 2>/dev/null)
                    KEPT=$(wc -l < "$savings_file" 2>/dev/null || echo 0)
                    if (( SAVED_BYTES > 0 )); then
                        SAVED_DISPLAY=$(numfmt --to=iec --format='%.2f' "$SAVED_BYTES" 2>/dev/null || echo "$SAVED_BYTES")
                    elif (( SAVED_BYTES < 0 )); then
                        local ABS=$(( -SAVED_BYTES ))
                        SAVED_DISPLAY="+"$(numfmt --to=iec --format='%.2f' "$ABS" 2>/dev/null || echo "$ABS")
                    fi
                fi
                # Truncate header to terminal width and Next filename to a max length
                local cols; cols=$(tput cols 2>/dev/null || echo 120)
                local next_base=""; [[ -n "$NEXT" ]] && next_base="$(basename -- "$NEXT")"
                local next_disp="$next_base"; local max_next=40
                if [[ -n "$next_disp" && ${#next_disp} -gt $max_next ]]; then
                    next_disp="${next_disp:0:$((max_next-3))}..."
                fi
                local header
                if [[ -n "$next_disp" ]]; then
                    header=$(printf "Parallel Progress: %d/%d done | Active: %d | Pending: %d | Kept: %d | Saved: %s | Next: %s" \
                        "$DONE" "$TOTAL" "$ACTIVE" "$PENDING" "$KEPT" "$SAVED_DISPLAY" "$next_disp")
                else
                    header=$(printf "Parallel Progress: %d/%d done | Active: %d | Pending: %d | Kept: %d | Saved: %s" \
                        "$DONE" "$TOTAL" "$ACTIVE" "$PENDING" "$KEPT" "$SAVED_DISPLAY")
                fi
                if (( ${#header} > cols )); then
                    header="${header:0:$((cols-1))}"
                fi
                printf "\033[2K%s\n" "$header"
                for ((i=1; i<=max_parallel_jobs; i++)); do
                    local pf="$log_dir/job${i}.progress"
                    local nf="$log_dir/job${i}.name"
                    local line
                    if [[ -f "$pf" ]]; then
                        # Read last line safely
                        line=$(tail -n 1 "$pf" 2>/dev/null)
                    else
                        line=""
                    fi
                    # Optional filename label
                    local label=""
                    if [[ -f "$nf" ]]; then
                        label="$(basename -- "$(cat "$nf" 2>/dev/null)")"
                    fi
                    # Truncate label to avoid wrapping
                    local max_label=40
                    if [[ -n "$label" && ${#label} -gt $max_label ]]; then
                        label="${label:0:$((max_label-3))}..."
                    fi
                    if [[ -n "$line" ]]; then
                        if [[ -n "$label" ]]; then
                            printf "\033[2K[Job%d] %s | %s\n" "$i" "$label" "$line"
                        else
                            printf "\033[2K[Job%d] %s\n" "$i" "$line"
                        fi
                    else
                        if [[ -n "$label" ]]; then
                            printf "\033[2K[Job%d] %s | waiting...\n" "$i" "$label"
                        else
                            printf "\033[2K[Job%d] waiting...\n" "$i"
                        fi
                    fi
                done
                # Return to end-of-panel anchor; do not emit extra text
                printf "\033[u"
                sleep 0.5
            done
        ) &
        PARALLEL_DISPLAY_PID=$!
    fi
}

stop_parallel_display() {
    if [[ -n "${PARALLEL_DISPLAY_PID:-}" ]]; then
        kill "$PARALLEL_DISPLAY_PID" 2>/dev/null || true
        wait "$PARALLEL_DISPLAY_PID" 2>/dev/null || true
        unset PARALLEL_DISPLAY_PID
        # Restore cursor and move to next line after the panel
        printf "\033[u\n"
    fi
}

# Parallel-aware encode function
encode_single_file_parallel() {
    local file="$1"
    local job_id="$2"
    local log_dir="$3"
    local job_log="$log_dir/job${job_id}.log"
    
    # Show real-time output with job prefix for parallel jobs
    if [[ $max_parallel_jobs -gt 1 ]]; then
        echo "[Job$job_id] Starting encode of $(basename "$file")"
        
        # Create log file first
        mkdir -p "$log_dir"
        echo "[Job$job_id] Starting encode of $(basename "$file")" > "$job_log"
        
        # Record file name for panel label
        echo "$file" > "$log_dir/job${job_id}.name"

        # Pre-populate progress line with a one-line summary before ffmpeg starts
        local progress_file="$log_dir/job${job_id}.progress"
        : > "$progress_file"
        {
            # Best-effort probe for summary (does not affect actual encode)
            local info
            if info=$(get_comprehensive_video_info "$file" 2>/dev/null); then
                eval "$info"
                local dur
                dur=$(format_duration "$DURATION")
                printf "Init: %sx%s %s | Dur %s | CRF %s Preset %s GOP %s\n" \
                    "${WIDTH:-?}" "${HEIGHT:-?}" "${V_PIX:-?}" \
                    "${dur:-Unknown}" "${crf}" "${preset}" "${gop}"
            else
                printf "Init: probing... | CRF %s Preset %s GOP %s\n" "${crf}" "${preset}" "${gop}"
            fi
        } > "$progress_file"

        # Temporarily suspend panel redraw to avoid interleaving with long command lines
        touch "$log_dir/.panel_suspend"
        # Watcher to resume panel once the first actual frame= progress appears
        (
            while true; do
                if grep -q '^frame=' "$progress_file" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            rm -f "$log_dir/.panel_suspend" 2>/dev/null || true
        ) &

        # No extra spacing here; spacing is added after the ffmpeg command log

        # Call encode function and process output for progress dashboard
        encode_single_file "$file" 2>&1 \
        | stdbuf -o0 -e0 tr '\r' '\n' \
        | stdbuf -oL tee -a "$job_log" \
        | stdbuf -oL tee >(stdbuf -oL sed -u \
                                -e '/^frame=/d' \
                                -e '/^Svt\[info\]:/d' \
                                -e "/^$/! s/^/[Job${job_id}] /" \
                                >&2) \
        | stdbuf -oL grep -E '^frame=' \
        > "$progress_file"
        
        local result=${PIPESTATUS[0]}
        echo "completed (exit=$result)" > "$progress_file"
        
        echo "[Job$job_id] Encoding completed with exit code: $result"
        # Ensure panel is resumed if encode finished too quickly
        rm -f "$log_dir/.panel_suspend" 2>/dev/null || true
        return $result
    else
        # Single job - use normal output
        encode_single_file "$file"
    fi
}

# Display encoding progress
display_encode_progress() {
    local total=$1
    local current=$2  
    local skipped=$3
    local total_saved_human
    
    # Handle negative total_space_saved properly
    if [[ $total_space_saved -gt 0 ]]; then
        total_saved_human=$(numfmt --to=iec --format="%.2f" "$total_space_saved")
    elif [[ $total_space_saved -lt 0 ]]; then
        local abs_total=$((total_space_saved * -1))
        total_saved_human="+$(numfmt --to=iec --format="%.2f" "$abs_total")"
    else
        total_saved_human="0.00"
    fi
    
    printf "\rProgress: [%d/%d] | Skipped: %d | Space Saved: %s" \
        "$current" "$total" "$skipped" "$total_saved_human"
}

# Main encoding function - streamlined and efficient
encode_single_file() {
    local file="$1"
    local presize presize_bytes start_time
    if ! presize_bytes=$(safe_stat_size "$file"); then
        log "Failed to access source file (missing or unreadable): $file" "31" true
        # Increment skipped count in parallel mode
        if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
            echo "1" >> "${PARALLEL_LOG_DIR}/skipped_count.tmp" 2>/dev/null || true
        fi
        return 1
    fi
    presize=$(numfmt --to=iec --format="%.2f" "$presize_bytes" 2>/dev/null || echo "Unknown")
    start_time=$SECONDS

    # Get ALL video info in one comprehensive call
    local video_info
    if ! video_info=$(get_comprehensive_video_info "$file"); then
        log "Failed to get video information for $file" "31" true
        return 1
    fi
    
    # Parse the structured output - now we have everything we need!
    eval "$video_info"

    # Dolby Vision handling: process HDR10-compatible profiles by stripping RPUs
    local dolby_needs_rpu_strip=false
    if [[ "$HDR_TYPE" == "dolby_vision" || "$IS_DOLBY_VISION" == "true" ]]; then
        local dv_profile_value="${DV_PROFILE:-none}"
        local dv_bl_compat="${DV_BL_COMPATIBILITY_ID:-none}"

        if [[ "$skip_dolby_vision" == true ]]; then
            log "Dolby Vision content detected - skipping per configuration" "31" true
            skipped_files=$((skipped_files + 1))
            if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
                echo "1" >> "${PARALLEL_LOG_DIR}/skipped_count.tmp" 2>/dev/null || true
            fi
            return 2
        fi

        if [[ "$dv_profile_value" != "7" && "$dv_profile_value" != "8" ]]; then
            log "Dolby Vision profile $dv_profile_value is not HDR10-compatible - skipping" "31" true
            skipped_files=$((skipped_files + 1))
            if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
                echo "1" >> "${PARALLEL_LOG_DIR}/skipped_count.tmp" 2>/dev/null || true
            fi
            return 2
        fi

        if [[ "$dv_bl_compat" == "0" || "$dv_bl_compat" == "none" ]]; then
            log "Dolby Vision stream lacks HDR10-compatible base layer - skipping" "31" true
            skipped_files=$((skipped_files + 1))
            if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
                echo "1" >> "${PARALLEL_LOG_DIR}/skipped_count.tmp" 2>/dev/null || true
            fi
            return 2
        fi

        dolby_needs_rpu_strip=true
        log "Dolby Vision profile $dv_profile_value detected (BL compatibility $dv_bl_compat) - converting base layer to HDR10" "32" true
    fi
    

    local duration_formatted
    duration_formatted=$(format_duration "$DURATION")
    
    echo "Processing: $(basename "$file")"
    echo "Size: $presize | Format: $FORMAT_UPPER | Runtime: $duration_formatted"
    log "HDR detection: $HDR_TYPE" "33" true
    log "Color metadata: transfer=$COLOR_TRANSFER, space=$COLOR_SPACE, primaries=$COLOR_PRIMARIES" "33" true

    # Run grain detection if enabled - removed grain eq - bug
    if [[ $detect_grain == true ]]; then
        detect_film_grain "$file"
    fi

    # If we’re adding grain, speed hack to off to retain quality
    if [[ $svt_film_grain -gt 0 ]]; then
        svt_fast_decode=0
    fi

    # Warn about film grain impact
    if [[ $svt_film_grain -gt 0 ]]; then
        log "WARNING: Film grain synthesis enabled (strength: $svt_film_grain). Encoding will be slower." "31" true
    fi
    
    log "Converting: $file (Size: $presize, Format: $FORMAT_UPPER)" "32" true

    # Setup file paths
    local temp_filename final_destination
    temp_filename="${temp_dir}/$(basename "$(transform_filename "$file")")"
    temp_filename=$(ensure_temp_filename "$temp_filename")
    
    final_destination=$(transform_filename "$file")
    final_destination=$(ensure_temp_filename "$final_destination")

    log "Encoding to temporary file: $temp_filename" "32" true
    log "Final destination will be: $final_destination" "32" true

    # Process audio and subtitles
    local audio_options=()
    if ! process_audio "$file" audio_options; then
        log "ERROR: Failed to process audio streams. Aborting encoding." "31" true
        return 1
    fi

    local subs_options
    read -ra subs_options <<< "$(check_subtitle_formats "$file")"

    # Setup scaling filters if needed
    local scale_filter=()
    local combined_filter=""

    # Build combined filter chain
    if [[ "$resize" == true && "$HEIGHT" -gt "$resize_target_height" ]]; then
        combined_filter="scale=-2:${resize_target_height}"
        log "Scaling video down to ${resize_target_height}p" "33" true
    fi

    # Apply the combined filter if we have any
    if [[ -n "$combined_filter" ]]; then
        scale_filter=("-vf" "$combined_filter")
    fi

    # Build the ffmpeg command - this becomes teh final command
    local cmd=()

    # Add 'nice' if lazy mode
    if [[ $lazy == true ]]; then
        cmd+=(nice -n 19)
    fi

    # In parallel mode, make ffmpeg unbuffer stderr/stdout for timely progress
    if [[ $max_parallel_jobs -gt 1 ]] && command -v stdbuf >/dev/null 2>&1; then
        cmd+=(stdbuf -oL -e0)
    fi

    # FFmpeg with appropriate logging
    if [[ $verbose == true ]]; then
        cmd+=("$ffmpeg_path" -hide_banner -loglevel info -stats)
    else
        cmd+=("$ffmpeg_path" -hide_banner -loglevel warning -stats)
    fi

    cmd+=(-max_delay 5000000 -fflags +genpts+discardcorrupt)
    
    cmd+=(-y -probesize 100M -analyzeduration 100M -i "$file")
    #cmd+=(-strict -2 -thread_type slice -threads:v:0 2)
    # Testing an improvement
    cmd+=(-strict -2)

    # Special handling for HDR content
    if [[ "$HDR_TYPE" != "none" && "$HEIGHT" -gt 1080 ]]; then
        log "Using specialized processing for HDR content" "33" true
        # Do NOT drop non-keyframes during transcoding; ensure full decode
        # Keep defaults for decoder threading; only tune encoder params below
        
        # Adjust settings for HDR
        svt_lookahead=20
        svt_enable_overlays=0
    fi

    # Map video stream
    cmd+=(-map 0:v:0)
    
    # Apply scaling if needed
    cmd+=("${scale_filter[@]}")
    
    # Map audio and subtitles
    cmd+=("${audio_options[@]}")
    cmd+=("${subs_options[@]}")

    if [[ $dolby_needs_rpu_strip == true ]]; then
        cmd+=(-bsf:v dovi_rpu=strip=1)
    fi
    
    # --- Video codec selection ---
    cmd+=(-c:v libsvtav1)
    log "Using software encoder: libsvtav1" "32" true

    local svt_params
    
    if [[ "$svt_film_grain" -gt 0 ]]; then
        # Grain synthesis mode - use content-specific settings from detect_film_grain
        log "Using grain synthesis mode with content-specific settings" "33" true
        # Note: svt_params_extra was already set by detect_film_grain() with appropriate denoise settings
        svt_enable_qm=0          # Turn off quantization matrices for grain
        svt_tile_columns=0       # Single tile for best quality with grain
        svt_fast_decode=0        # Disable fast decode when preserving grain
        
        # Full parameter set for grain preservation
        svt_params=$(printf "tune=%s:enable-overlays=%s:fast-decode=%s:keyint=%s:lookahead=%s:aq-mode=2:enable-qm=%s:qm-min=%s:qm-max=%s:tile-columns=%s:film-grain=%s%s" \
            "$svt_tune" "$svt_enable_overlays" "$svt_fast_decode" "$gop" "$svt_lookahead" \
            "$svt_enable_qm" "$svt_qm_min" "$svt_qm_max" "$svt_tile_columns" "$svt_film_grain" "${svt_params_extra}")
    else
        # Standard encoding - minimal params, let SVT-AV1 use sensible defaults
        log "Using standard encoding mode with minimal parameters" "33" true
        
        # Just the basics - avoid the warning-prone combinations
        svt_params="keyint=${gop}"
        
        # Only add tune if it's not the default (1/VMAF)
        if [[ "$svt_tune" -ne 1 ]]; then
            svt_params+=":tune=${svt_tune}"
        fi
    fi

    # Software encoder parameters
    cmd+=(-svtav1-params "$svt_params")
    log "Using SVT-AV1 parameters: $svt_params" "33" true

    # Additional verbose logging for software encoding
    if [[ $verbose == true ]]; then
        log "Detailed SVT-AV1 params: $svt_params" "33" true
    fi
    
    # Determine optimal pixel format based on source bit-depth
    determine_pixel_format() {
        local source_pix="$1"
        case "$source_pix" in
            # 10-bit source formats
            yuv420p10le|yuv422p10le|yuv444p10le|p010le|yuv420p10be|yuv422p10be|yuv444p10be)
                echo "yuv420p10le"  # Keep 10-bit for 10-bit sources
                ;;
            # 8-bit source formats
            yuv420p|yuv422p|yuv444p|nv12|nv21)
                echo "yuv420p"     # Use 8-bit for 8-bit sources - much better AV1 efficiency
                ;;
            *)
                # Unknown/unsupported format - default based on HDR type
                if [[ "$HDR_TYPE" != "none" ]]; then
                    echo "yuv420p10le"  # HDR typically needs 10-bit
                else
                    echo "yuv420p"      # SDR can use efficient 8-bit
                fi
                ;;
        esac
    }

    output_pix_fmt=$(determine_pixel_format "$V_PIX")
    log "Source: $V_PIX -> Output: $output_pix_fmt" "33" true

    # Set encoding parameters based on HDR type
    if [[ "$HDR_TYPE" != "none" ]]; then
        if [[ "$HDR_TYPE" == "dolby_vision" && $dolby_needs_rpu_strip == true ]]; then
            log "Dolby Vision base layer detected - encoding as HDR10 with metadata preserved" "33" true
        else
            log "Preserving HDR metadata for $HDR_TYPE content" "33" true
        fi

        # Add software encoding parameters for HDR content
        cmd+=(-preset "$preset" -crf "$crf" -pix_fmt "$output_pix_fmt" -g "$gop")

        # Preserve or fallback color metadata appropriate for HDR10
        if [[ -n "$COLOR_PRIMARIES" && "$COLOR_PRIMARIES" != "unknown" ]]; then
            cmd+=(-color_primaries "$COLOR_PRIMARIES")
        else
            cmd+=(-color_primaries bt2020)
        fi

        if [[ -n "$COLOR_TRANSFER" && "$COLOR_TRANSFER" != "unknown" ]]; then
            cmd+=(-color_trc "$COLOR_TRANSFER")
        else
            cmd+=(-color_trc smpte2084)
        fi

        if [[ -n "$COLOR_RANGE" && "$COLOR_RANGE" != "unknown" ]]; then
            cmd+=(-color_range "$COLOR_RANGE")
        else
            cmd+=(-color_range tv)
        fi

        if [[ -n "$COLOR_SPACE" && "$COLOR_SPACE" != "unknown" ]]; then
            cmd+=(-colorspace "$COLOR_SPACE")
        else
            cmd+=(-colorspace bt2020nc)
        fi

        # Add HDR10 static metadata where available to trigger correct HDR on players
        if [[ -n "$MASTER_DISPLAY" ]]; then
            cmd+=(-master_display "$MASTER_DISPLAY")
        fi
        if [[ -n "$CONTENT_LIGHT" ]]; then
            cmd+=(-content_light "$CONTENT_LIGHT")
        fi
    else
        # Standard dynamic range - preserve original color metadata
        log "Standard dynamic range content - preserving color metadata" "33" true
        cmd+=(-preset "$preset" -crf "$crf" -pix_fmt "$output_pix_fmt" -g "$gop")

        if [[ -n "$COLOR_PRIMARIES" && "$COLOR_PRIMARIES" != "unknown" ]]; then
            cmd+=(-color_primaries "$COLOR_PRIMARIES")
            log "Preserving color primaries: $COLOR_PRIMARIES" "33"
        fi
        if [[ -n "$COLOR_TRANSFER" && "$COLOR_TRANSFER" != "unknown" ]]; then
            cmd+=(-color_trc "$COLOR_TRANSFER")
            log "Preserving color transfer: $COLOR_TRANSFER" "33"
        fi
        if [[ -n "$COLOR_SPACE" && "$COLOR_SPACE" != "unknown" ]]; then
            cmd+=(-colorspace "$COLOR_SPACE")
            log "Preserving color space: $COLOR_SPACE" "33"
        fi

        if [[ -n "$COLOR_RANGE" && "$COLOR_RANGE" != "unknown" ]]; then
            cmd+=(-color_range "$COLOR_RANGE")
        else
            cmd+=(-color_range tv)
        fi
    fi
    
    cmd+=(-threads "$ffmpeg_threads")
    cmd+=("$temp_filename")

    # Log the command
    log "Running ffmpeg command: $(printf '%q ' "${cmd[@]}")" "32" true
    # In parallel mode, add spacing after the command to avoid panel redraw overlap
    if [[ ${max_parallel_jobs:-1} -gt 1 ]]; then
        printf "\n\n" >&2
    fi

    # Execute the encoding
    if "${cmd[@]}"; then
        # Verify the temp file
        if [[ ! -f "$temp_filename" || ! -s "$temp_filename" ]]; then
            log "Error: Encoding completed but temp file is missing or empty" "31" true
            return 1
        fi
        
        # Set default audio track
        log "Setting default audio track for $temp_filename" "32" true
        set_default_audio_track "$temp_filename"
        
        # Move to final destination
        if ! move_completed_file "$temp_filename" "$final_destination"; then
            log "Failed to move encoded file to final destination" "31" true
            return 1
        fi
        
        # POST-ENCODE SIZE CHECK - Handle larger files based on user preference
        local original_size_bytes encoded_size_bytes
        original_size_bytes=$(safe_stat_size "$file" 2>/dev/null || echo 0)
        encoded_size_bytes=$(safe_stat_size "$final_destination" 2>/dev/null || echo 0)
        
        if [[ -n "$original_size_bytes" && -n "$encoded_size_bytes" ]]; then
            if (( encoded_size_bytes >= original_size_bytes )); then
                if [[ $allow_larger_files == false ]]; then
                    log "AV1 encode is of a higher physical size, reverting" "31" true
                
                # Calculate bitrate and get codec for reporting
                local bitrate_mbps duration_seconds input_bitrate codec_name
                duration_seconds=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null || echo "0")
                codec_name=$(ffprobe -v quiet -show_entries stream=codec_name -select_streams v:0 -of csv=p=0 "$file" 2>/dev/null || echo "unknown")
                
                if [[ -n "$duration_seconds" && "$duration_seconds" != "0" && "$duration_seconds" != "N/A" ]]; then
                    input_bitrate=$(echo "scale=0; $original_size_bytes * 8 / $duration_seconds" | bc -l 2>/dev/null || echo "0")
                    bitrate_mbps=$(echo "scale=1; $input_bitrate / 1000000" | bc -l 2>/dev/null || echo "Unknown")
                else
                    bitrate_mbps="Unknown"
                fi
                
                # Add to reverted files list: filepath|codec|bitrate|original_size_bytes
                reverted_files+=("$file|$codec_name|${bitrate_mbps}Mbps|$original_size_bytes")
                
                # Remove the encoded file and keep original
                rm -f "$final_destination"
                log "Reverted to original file: $(basename "$file")" "33" true
                
                    # In parallel mode, write to temp file for parent process tracking (reverts count as processed)
                    if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
                        echo "1" >> "${PARALLEL_LOG_DIR}/processed_count.tmp" 2>/dev/null || true
                    fi
                    
                    return 3  # Special return code for "reverted due to size"
                else
                    # User allows larger files - keep the AV1 version
                    local size_increase=$((encoded_size_bytes - original_size_bytes))
                    local size_increase_human
                    size_increase_human=$(numfmt --to=iec --format="%.2f" "$size_increase")
                    log "AV1 encode is larger (+$size_increase_human) but keeping as requested" "33" true
                    
                    # Update statistics to reflect the size increase (negative savings)
                    total_space_saved=$((total_space_saved - size_increase))
                fi
            fi
        fi
        
        # Calculate space saved BEFORE removing the original file
        local original_bytes new_bytes saved_bytes space_saved_human

        # Get file sizes in bytes (not formatted)
        original_bytes=$(safe_stat_size "$file" 2>/dev/null || echo 0)
        new_bytes=$(safe_stat_size "$final_destination" 2>/dev/null || echo 0)

        if [[ -n "$original_bytes" && -n "$new_bytes" ]]; then
            # Calculate bytes saved (can be negative if file got larger)
            saved_bytes=$((original_bytes - new_bytes))
            
            # Update the global total
            total_space_saved=$((total_space_saved + saved_bytes))
            # If running in parallel mode, append to savings tracker for panel header
            if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
                printf "%s\n" "$saved_bytes" >> "${PARALLEL_LOG_DIR}/savings.lines" 2>/dev/null || true
                # Also append raw sizes so final summary can be accurate in parallel mode
                printf "%s\n" "$original_bytes" >> "${PARALLEL_LOG_DIR}/originals.lines" 2>/dev/null || true
                printf "%s\n" "$new_bytes" >> "${PARALLEL_LOG_DIR}/finals.lines" 2>/dev/null || true
            fi
            
            # Format for human-readable display - handle negative numbers properly
            if [[ $saved_bytes -lt 0 ]]; then
                # File got larger - format as positive number and add "+" prefix
                local abs_saved_bytes=$((saved_bytes * -1))
                space_saved_human="+$(numfmt --to=iec --format="%.2f" "$abs_saved_bytes")"
            else
                # File got smaller - normal formatting
                space_saved_human=$(numfmt --to=iec --format="%.2f" "$saved_bytes")
            fi
        else
            space_saved_human="N/A"
            log "WARNING: Could not calculate space saved" "31"
        fi

        # Add to global totals for batch summary (sequential mode)
        if [[ -z "${PARALLEL_LOG_DIR:-}" ]]; then
            if [[ -n "$original_bytes" && -n "$new_bytes" ]]; then
                total_original_bytes=$((total_original_bytes + original_bytes))
                total_final_bytes=$((total_final_bytes + new_bytes))
            fi
        fi

        # Update statistics
        log "Updating MKV statistics for $final_destination" "32" true
        update_mkv_statistics "$file" "$final_destination"
        
        # NOW remove source file if requested (AFTER all calculations)
        if [[ $remove_input_file == true ]]; then
            rm -f "$file"
            log "Source file $file removed." "31" true
        fi
        
        # Display the space saved for this file
        echo "Space Change: $space_saved_human"
        echo
        
        # In parallel mode, write to temp file for parent process tracking
        if [[ -n "${PARALLEL_LOG_DIR:-}" ]]; then
            echo "1" >> "${PARALLEL_LOG_DIR}/processed_count.tmp" 2>/dev/null || true
        fi
        
        return 0
    else
        log "Encoding failed for $file" "31" true
        [[ -f "$temp_filename" ]] && rm -f "$temp_filename"
        return 1
    fi
}

# ============================================================================
# STATISTICS AND METADATA FUNCTIONS
# ============================================================================

# Configuration for table appearance
declare -g TABLE_WIDTH=86  # Total table width
declare -g COL1_WIDTH=36   # First column (filenames/labels) - wider for readability
declare -g COL2_WIDTH=16   # Second column (sizes/values)  
declare -g COL3_WIDTH=24   # Third column (codec/bitrate info)

# Table formatting functions
hr() {
    printf '+%s+\n' "$(head -c $((TABLE_WIDTH-2)) < /dev/zero | tr '\0' '-')"
}

pad_and_truncate() {
    local input="$1"
    local width="$2"
    local result="$input"
    # Truncate with ellipsis if too long
    if (( ${#result} > width )); then
        result="${result:0:$((width-3))}..."
    fi
    printf "%-${width}s" "$result"
}

format_row() {
    printf "| %s | %s | %s |\n" \
        "$(pad_and_truncate "$1" "$COL1_WIDTH")" \
        "$(pad_and_truncate "$2" "$COL2_WIDTH")" \
        "$(pad_and_truncate "$3" "$COL3_WIDTH")"
}

format_section() {
    local text="$1"
    local width=$((TABLE_WIDTH-4))
    # Truncate with ellipsis if necessary
    if (( ${#text} > width )); then
        text="${text:0:$((width-3))}..."
    fi
    printf "| %-${width}s |\n" "$text"
}

truncate_filename() {
    local filename="$1"
    local max_length=$((COL1_WIDTH - 2))  # Use column width minus padding
    if [[ ${#filename} -le $max_length ]]; then
        echo "$filename"
    else
        local ext=".${filename##*.}"
        echo "${filename:0:$((max_length-${#ext}-3))}...$ext"
    fi
}

calculate_percentage() {
    local old="$1"
    local new="$2"
    
    if [[ -z "$old" || "$old" == "null" || "$old" == "0" || -z "$new" || "$new" == "null" ]]; then
        echo "N/A"
    else
        awk "BEGIN {printf \"%.2f\", (($old-$new)/$old)*100}"
    fi
}

display_encoding_statistics() {
    local input_file="$1"
    local output_file="$2"
    local input_codec="$3"
    local output_codec="$4"
    local input_size="$5"
    local output_size="$6"
    local formatted_input_bitrate="$7"
    local formatted_output_bitrate="$8"
    local input_framerate="$9"
    local output_framerate="${10}"
    local filesize_reduction="${11}"
    local formatted_time="${12}"
    local preset="${13}"
    local crf="${14}"
    local svt_film_grain="${15}"
    local gop="${16}"

    local display_filename
    display_filename=$(truncate_filename "$(basename "$output_file")")

    echo
    hr
    format_section "Encoding Statistics for $display_filename"
    hr
    format_row "Metric" "Original" "Encoded"
    hr
    format_row "Codec" "$input_codec" "$output_codec"
    format_row "File Size" "$(numfmt --to=iec --format='%.2f' "$input_size")" "$(numfmt --to=iec --format='%.2f' "$output_size")"
    format_row "Bitrate" "${formatted_input_bitrate} Mbps" "${formatted_output_bitrate} Mbps"
    format_row "Frame Rate" "$input_framerate" "$output_framerate"
    hr
    format_section "Compression Results"
    hr
    format_row "Size Change" "${filesize_reduction}%" "Space change %"
    format_row "Encode Time" "$formatted_time" "Total Duration"
    hr
    format_section "Encoding Parameters Used"
    hr
    format_row "Preset" "$preset" "Speed/Quality"
    format_row "CRF" "$crf" "Quality Factor"
    format_row "Film Grain" "$svt_film_grain" "Grain Synthesis"
    format_row "GOP Size" "$gop" "Keyframe Interval"
    hr
    echo
}

# Display detailed report of reverted files with recommendations
display_reverted_files_report() {
    if [[ ${#reverted_files[@]} -eq 0 ]]; then
        return  # No reverted files, nothing to display
    fi
    
    echo
    hr
    format_section "REVERTED FILES REPORT - AV1 LARGER THAN ORIGINAL"
    hr
    format_row "File" "Original Size" "Codec/Bitrate"
    hr
    
    local total_reverted=0
    local total_reverted_size=0
    
    for file_info in "${reverted_files[@]}"; do
        # Parse the stored file info: "filename|codec|bitrate|original_size_bytes"
        local filename codec bitrate original_size_bytes
        IFS='|' read -r filename codec bitrate original_size_bytes <<< "$file_info"
        
        # Truncate long filenames for table formatting
        local display_name
        display_name=$(truncate_filename "$(basename "$filename")")
        
        # Format original size for display
        local original_size_human
        original_size_human=$(numfmt --to=iec --format="%.2f" "$original_size_bytes")
        
        # Format codec and bitrate info
        local codec_info="${codec}"
        if [[ "$bitrate" != "Unknown" && "$bitrate" != "N/A" ]]; then
            codec_info="${codec} @ ${bitrate}"
        fi
        
        format_row "$display_name" "$original_size_human" "$codec_info"
        
        total_reverted=$((total_reverted + 1))
        # Add raw bytes to total
        total_reverted_size=$((total_reverted_size + original_size_bytes))
    done
    
    hr
    local total_reverted_human
    total_reverted_human=$(numfmt --to=iec --format="%.2f" "$total_reverted_size")
    format_row "TOTAL REVERTED" "$total_reverted files" "$total_reverted_human"
    hr
    format_section "RECOMMENDATIONS"
    hr
    
    if [[ $total_reverted -gt 0 ]]; then
        format_section "* Increase CRF value (e.g., CRF 25->28) for better compression"
        format_section "* Review source quality - files may already be well-compressed"
        format_section "* Low bitrate files may not compress further with AV1"
        format_section "* Try --preset slower for better efficiency"
    fi
    hr
    echo
}

display_batch_summary() {
    local total_processed="$1"
    local total_skipped="$2"
    local overall_duration="$3"
    
    # Calculate overall statistics
    local total_files=$((total_processed + total_skipped))
    local overall_reduction_percentage
    
    if [[ $total_original_bytes -gt 0 ]]; then
        overall_reduction_percentage=$(awk "BEGIN {printf \"%.2f\", (($total_original_bytes-$total_final_bytes)/$total_original_bytes)*100}")
    else
        overall_reduction_percentage="0.00"
    fi
    
    # Format the sizes for display - handle negative space saved
    local formatted_original_size formatted_final_size formatted_space_saved
    formatted_original_size=$(numfmt --to=iec --format="%.2f" "$total_original_bytes")
    formatted_final_size=$(numfmt --to=iec --format="%.2f" "$total_final_bytes")
    
    # Handle negative total_space_saved for display
    if [[ $total_space_saved -gt 0 ]]; then
        formatted_space_saved=$(numfmt --to=iec --format="%.2f" "$total_space_saved")
    elif [[ $total_space_saved -lt 0 ]]; then
        local abs_total=$((total_space_saved * -1))
        formatted_space_saved="+$(numfmt --to=iec --format="%.2f" "$abs_total") (grew)"
    else
        formatted_space_saved="0.00"
    fi
    
    # Format the duration
    local hours=$((overall_duration / 3600))
    local minutes=$(( (overall_duration % 3600) / 60 ))
    local seconds=$((overall_duration % 60))
    local formatted_duration=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
    
    # Calculate average processing time per file (excluding skipped files)
    local avg_time_per_file="N/A"
    if [[ $total_processed -gt 0 ]]; then
        local avg_seconds=$((overall_duration / total_processed))
        local avg_hours=$((avg_seconds / 3600))
        local avg_mins=$(( (avg_seconds % 3600) / 60 ))
        local avg_secs=$((avg_seconds % 60))
        avg_time_per_file=$(printf "%02d:%02d:%02d" $avg_hours $avg_mins $avg_secs)
    fi
    
    echo
    echo
    hr
    format_section "BATCH PROCESSING COMPLETE - FINAL SUMMARY"
    hr
    format_row "Metric" "Count/Size" "Details"
    hr
    format_row "Total Files Found" "$total_files" "All eligible files"
    format_row "Files Processed" "$total_processed" "Successfully encoded"
    format_row "Files Skipped" "$total_skipped" "Dolby Vision/errors"
    hr
    format_section "Size & Compression Analysis"
    hr
    format_row "Original Total Size" "$formatted_original_size" "Before encoding"
    format_row "Final Total Size" "$formatted_final_size" "After encoding"
    format_row "Total Space Change" "$formatted_space_saved" "Storage change"
    format_row "Overall Change" "${overall_reduction_percentage}%" "Size difference"
    hr
    format_section "Time & Performance Metrics"
    hr
    format_row "Total Processing Time" "$formatted_duration" "Wall clock time"
    format_row "Average per File" "$avg_time_per_file" "Processing efficiency"
    hr
    
    # Display reverted files report if any files were reverted
    display_reverted_files_report
    
    hr
    format_section "Mission Results"
    hr
    
    # Adjust commentary for negative results
    local reduction_abs
    reduction_abs=$(echo "$overall_reduction_percentage" | tr -d '-')
    
    if [[ "$overall_reduction_percentage" =~ ^- ]]; then
        # Files got larger
        if (( $(echo "$reduction_abs > 20" | bc -l) )); then
            format_section "Files grew significantly. Might want to adjust CRF or check source quality."
        elif (( $(echo "$reduction_abs > 10" | bc -l) )); then
            format_section "Files grew moderately. Consider tweaking encoding settings."
        else
            format_section "Minimal size increase. Quality vs size trade-off at work."
        fi
    else
        # Files got smaller (original logic)
        if (( $(echo "$overall_reduction_percentage > 50" | bc -l) )); then
            format_section "Excellent compression! You've freed up serious storage space."
        elif (( $(echo "$overall_reduction_percentage > 30" | bc -l) )); then
            format_section "Good compression achieved. Every gigabyte counts!"
        elif (( $(echo "$overall_reduction_percentage > 10" | bc -l) )); then
            format_section "Modest gains, but still worthwhile for your library."
        else
            format_section "Minimal space saved. Source files were likely well compressed already."
        fi
    fi
    hr
    echo
}

# Update MKV statistics and metadata
update_mkv_statistics() {
    local input_file="$1"
    local output_file="$2"
    
    # Calculate bitrate from file size and duration
    calculate_bitrate() {
        local file_size="$1"
        local duration="$2"
        
        if [[ -z "$duration" || "$duration" == "null" || "$duration" == "0" ]]; then
            echo "0"
            return
        fi
        
        echo "scale=2; ($file_size * 8) / ($duration * 1024)" | bc -l
    }

    # Get file information
    local input_stats output_stats
    input_stats=$(get_comprehensive_video_info "$input_file")
    output_stats=$(get_comprehensive_video_info "$output_file")
    
    eval "$input_stats"
    local input_codec="$CODEC_NAME"
    local input_duration="$DURATION"
    local input_framerate="$FRAMERATE"
    
    eval "$output_stats"
    local output_codec="$CODEC_NAME"
    local output_duration="$DURATION"
    local output_framerate="$FRAMERATE"

    # Get file sizes and calculate bitrates
    local input_size output_size
    input_size=$(safe_stat_size "$input_file" || echo 0)
    output_size=$(safe_stat_size "$output_file" || echo 0)
    
    local input_bitrate output_bitrate
    input_bitrate=$(calculate_bitrate "$input_size" "$input_duration")
    output_bitrate=$(calculate_bitrate "$output_size" "$output_duration")
    
    # Format for display
    local formatted_input_bitrate formatted_output_bitrate
    formatted_input_bitrate=$(echo "scale=2; $input_bitrate / 1024" | bc)
    formatted_output_bitrate=$(echo "scale=2; $output_bitrate / 1024" | bc)
    
    # Calculate reductions
    local filesize_reduction bitrate_reduction
    filesize_reduction=$(calculate_percentage "$input_size" "$output_size")
    bitrate_reduction=$(calculate_percentage "$input_bitrate" "$output_bitrate")

    # Calculate encoding time
    local encode_time=$((SECONDS - start_time))
    local hours=$((encode_time / 3600))
    local minutes=$(( (encode_time % 3600) / 60 ))
    local seconds=$((encode_time % 60))
    local formatted_time=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
        
    # Create tags file
    local tags_file=$(mktemp)
    cat > "$tags_file" << EOF
<?xml version="1.0"?>
<Tags>
  <Tag>
    <Targets>
      <TargetTypeValue>50</TargetTypeValue>
    </Targets>
    <Simple>
      <Name>SOURCE_CODEC</Name>
      <String>$input_codec</String>
    </Simple>
    <Simple>
      <Name>TARGET_CODEC</Name>
      <String>$output_codec</String>
    </Simple>
    <Simple>
      <Name>ENCODE_DATE</Name>
      <String>$(date '+%Y-%m-%d %H:%M:%S')</String>
    </Simple>
    <Simple>
      <Name>SOURCE_FILESIZE</Name>
      <String>$(numfmt --to=iec --format='%.2f' "$input_size")</String>
    </Simple>
    <Simple>
      <Name>TARGET_FILESIZE</Name>
      <String>$(numfmt --to=iec --format='%.2f' "$output_size")</String>
    </Simple>
    <Simple>
      <Name>SIZE_REDUCTION</Name>
      <String>${filesize_reduction}%</String>
    </Simple>
    <Simple>
      <Name>SOURCE_BITRATE</Name>
      <String>${formatted_input_bitrate} Mbps</String>
    </Simple>
    <Simple>
      <Name>TARGET_BITRATE</Name>
      <String>${formatted_output_bitrate} Mbps</String>
    </Simple>
    <Simple>
      <Name>ENCODE_SETTINGS</Name>
      <String>preset:$preset,crf:$crf,grain:$svt_film_grain</String>
    </Simple>
    <Simple>
      <Name>ENCODED_BY</Name>
      <String>Re-encoded by $reencoded_by</String>
    </Simple>
  </Tag>
</Tags>
EOF

    # Update metadata
    local cmd=(mkvpropedit "$output_file"
        --edit info --set "title=${output_file%.*}"
        --tags global:"$tags_file")
    
    if "${cmd[@]}"; then
        rm -f "$tags_file"
        log "Updated MKV metadata and statistics for $output_file" "32" true
        
        # Display statistics table
        display_encoding_statistics \
        "$input_file" "$output_file" \
        "$input_codec" "$output_codec" \
        "$input_size" "$output_size" \
        "$formatted_input_bitrate" "$formatted_output_bitrate" \
        "$input_framerate" "$output_framerate" \
        "$filesize_reduction" "$formatted_time" \
        "$preset" "$crf" "$svt_film_grain" "$gop"
    else
        rm -f "$tags_file"
        log "Failed to update MKV metadata for $output_file" "31" true
    fi
}

# ============================================================================
# MAIN FUNCTION
# ============================================================================

main() {
    # Reset terminal formatting at start to ensure clean state
    printf '\033[0m'
    
    # initialise configuration system first - this loads defaults and config file
    if ! initialise_config; then
        log "Configuration initialization failed" "31" true
        exit 1
    fi

    # Make sure these settings are valid
    parse_arguments "$@"

    # Validate final configuration after all sources have been processed
    if ! validate_config; then
        log "Configuration validation failed" "31" true
        exit 1
    fi

    display_config false

    check_dependencies
    setup_temp_directory
    overall_start_time=$SECONDS

    generate_video_list
    
    local corrupted_files=()
    local ffprobe_errors=()
    local filtered_convlist=()
    local processed_files=0
    
    # Filter video list
    if ! mapfile -t convlist < <(filter_video_list); then
        echo "No files to convert after filtering."
        exit 0
    fi

    if [[ ${#convlist[@]} -eq 0 ]]; then
        echo "No files to convert after filtering."
        exit 0
    fi

    # Initialize missing files tracking
    missing_files_list=()
    
    log "Verifying files are readable..." "34" true
    for file in "${convlist[@]}"; do
        if ! video_info=$(get_comprehensive_video_info "$file"); then
            corrupted_files+=("$file")
            ffprobe_errors+=("File appears to be corrupted or invalid")
        else
            filtered_convlist+=("$file")
        fi
    done

    convlist=("${filtered_convlist[@]}")
    local total_files=${#convlist[@]}

    if [[ $total_files -eq 0 ]]; then
        echo "No valid files to process after removing corrupted files."
        exit 0
    fi

    # Report any corrupted files
    if [[ ${#corrupted_files[@]} -gt 0 ]]; then
        echo
        echo "WARNING: Found ${#corrupted_files[@]} corrupted/invalid files (skipped):"
        printf '%s\n' "${corrupted_files[@]}" | sed 's:^.*/::' | sort
        echo
        echo "Proceeding with $total_files valid files"
        echo
    fi
    
    # Display files to be processed
    log "Files to convert:" "32" true
    for ((i=0; i<total_files; i++)); do
        file="${convlist[i]}"
        video_info=$(get_comprehensive_video_info "$file")
        eval "$video_info"
        
        file_size=$(get_file_size "$file")
        new_filename=$(transform_filename "$file")
        
        echo -e "\nProcessing file [$((i+1))/$total_files]"
        log "Original: $file" "32" true
        log "Size: $file_size, Format: $FORMAT_UPPER" "32" true
        log "Will be renamed to: $new_filename" "32" true
    done

    # Confirmation prompt
    if [[ $force != true ]]; then
        echo
        read -rp "Do you want to process these files? (y/n/1 for single file) " choice
        case $choice in
            [Yy]*)
                log "User chose to process all files" "34" true
                ;;
            [Nn]*)
                log "User chose to exit" "34" true
                exit 
                ;;
            1)
                log "User chose single file selection" "34" true
                select file in "${convlist[@]}"; do
                    if [[ -n $file ]]; then
                        log "User selected file: $file" "34" true
                        encode_single_file "$file"
                    else
                        log "Invalid file selection" "31" true
                    fi
                    break
                done
                exit
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
    else
        log "Force mode enabled, proceeding with all files" "34" true
    fi

    # Process files - parallel or sequential based on configuration
    echo  # Start with a fresh line for progress tracking
    
    if [[ $max_parallel_jobs -gt 1 ]]; then
        # PARALLEL PROCESSING MODE
        log "Starting parallel processing with $max_parallel_jobs concurrent jobs" "34" true
        
        # Create temporary log directory for parallel jobs
        local parallel_log_dir="$temp_dir/parallel_logs"
        mkdir -p "$parallel_log_dir"
        
        # Initialize parallel processing
        start_parallel_display "$parallel_log_dir"
        # Initialize queue status for header and savings tracker
        local started_jobs=0
        printf "TOTAL=%d\nSTARTED=%d\nPROCESSED=%d\nSKIPPED=%d\nACTIVE=%d\n" \
            "$total_files" "$started_jobs" "$processed_files" "$skipped_files" 0 > "$parallel_log_dir/queue_status"
        : > "$parallel_log_dir/savings.lines"
        # Initialize count tracking files for parallel jobs
        : > "$parallel_log_dir/processed_count.tmp"
        : > "$parallel_log_dir/skipped_count.tmp"
        export PARALLEL_LOG_DIR="$parallel_log_dir"
        
        # Set up signal handler for clean shutdown of parallel jobs
        cleanup_parallel_jobs() {
            # Simple terminal reset
            echo
            stty sane 2>/dev/null
            tput sgr0 2>/dev/null
            
            log "Interrupt received - stopping all parallel jobs..." "31" true
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    log "Terminating job with PID $pid" "33" true
                    kill -TERM "$pid" 2>/dev/null || true
                    # Give it a moment to cleanup
                    sleep 1
                    # Force kill if still running
                    kill -9 "$pid" 2>/dev/null || true
                fi
            done
            stop_parallel_display
            log "All parallel jobs terminated" "31" true
            exit 1
        }
        trap cleanup_parallel_jobs INT TERM
        
        # Process files in parallel batches - This will hurt your CPU!
        local active_jobs=0
        declare -a job_pids=()
        declare -a job_files=()
        declare -a job_slots=()           # slot id per job index
        local -a slots_in_use=()          # slots 1..max_parallel_jobs marked as 1 when occupied
        for ((s=1; s<=max_parallel_jobs; s++)); do slots_in_use[$s]=0; done
        
        for ((i=0; i<total_files; i++)); do
            # Check for interrupt signal to exit entire queue
            if [[ $should_exit_queue == true ]]; then
                printf "\n\033[33mExiting queue processing as requested...\033[0m\n"
                break
            fi
            
            # Wait if we've reached max parallel jobs
            while [[ $active_jobs -ge $max_parallel_jobs ]]; do
                # Check for completed jobs
                for ((j=0; j<${#job_pids[@]}; j++)); do
                    if ! kill -0 "${job_pids[j]}" 2>/dev/null; then
                        # Job completed, get result and clean up
                        wait "${job_pids[j]}"
                        result=$?
                        
                        current_file="${job_files[j]}"
                        slot_id="${job_slots[j]}"
                        
                        # Handle job result
                        if [[ $result -eq 1 ]]; then
                            # File missing/unreadable - treat as skipped
                            echo "1" >> "$parallel_log_dir/skipped_count.tmp" 2>/dev/null || true
                            skipped_files=$(wc -l < "$parallel_log_dir/skipped_count.tmp" 2>/dev/null || echo 0)
                            log "SKIPPED: File missing or unreadable: $current_file" "33" true
                        elif [[ $result -eq 2 ]]; then
                            # Skipped due to Dolby Vision (unsupported or disabled) - count from temp file
                            skipped_files=$(wc -l < "$parallel_log_dir/skipped_count.tmp" 2>/dev/null || echo 0)
                            log "SKIPPED: Dolby Vision unsupported/disabled: $current_file" "33" true
                        elif [[ $result -eq 3 ]]; then
                            # Reverted due to AV1 being larger; still a completed attempt - count from temp file
                            processed_files=$(wc -l < "$parallel_log_dir/processed_count.tmp" 2>/dev/null || echo 0)
                            log "REVERTED: AV1 file was larger than original: $current_file" "33" true
                        else
                            # Successful encode - count from temp file
                            processed_files=$(wc -l < "$parallel_log_dir/processed_count.tmp" 2>/dev/null || echo 0)
                        fi
                        
                        # Free the slot for reuse and clear label files
                        slots_in_use[$slot_id]=0
                        rm -f "$parallel_log_dir/job${slot_id}.name" 2>/dev/null || true
                        # keep progress line; encode function writes completed message

                        # Update queue status (after decrementing active jobs below)
                        printf "TOTAL=%d\nSTARTED=%d\nPROCESSED=%d\nSKIPPED=%d\nACTIVE=%d\nNEXT=%s\n" \
                            "$total_files" "$started_jobs" "$processed_files" "$skipped_files" $((active_jobs - 1)) "" > "$parallel_log_dir/queue_status"

                        # Remove completed job from arrays
                        unset job_pids[j]
                        unset job_files[j]
                        unset job_slots[j]
                        job_pids=("${job_pids[@]}")
                        job_files=("${job_files[@]}")
                        job_slots=("${job_slots[@]}")
                        active_jobs=$((active_jobs - 1))
                        break
                    fi
                done
                [[ $active_jobs -ge $max_parallel_jobs ]] && sleep 1
            done
            
            # Start new job
            current_file="${convlist[i]}"
            
            # Check if file still exists before processing
            if [[ ! -f "$current_file" ]]; then
                log "WARNING: File disappeared from queue: $current_file" "31" true
                notify "Missing File Warning" "File disappeared from queue: $(basename "$current_file")"
                printf '\a'  # Terminal bell
                echo "$current_file" >> "$parallel_log_dir/missing_files.tmp"
                echo "1" >> "$parallel_log_dir/skipped_count.tmp"
                continue
            fi
            
            # Find first free panel slot (1..max_parallel_jobs)
            slot_id=0
            for ((s=1; s<=max_parallel_jobs; s++)); do
                if [[ ${slots_in_use[$s]} -eq 0 ]]; then slot_id=$s; break; fi
            done
            if [[ $slot_id -eq 0 ]]; then
                # Should not happen because we gate by active_jobs
                slot_id=$(( (active_jobs % max_parallel_jobs) + 1 ))
            fi
            slots_in_use[$slot_id]=1
            job_id=$slot_id
            # Launch parallel job; per-job startup is printed inside the job function
            encode_single_file_parallel "$current_file" "$job_id" "$parallel_log_dir" &
            job_pids+=($!)
            job_files+=("$current_file")
            job_slots+=("$job_id")
            active_jobs=$((active_jobs + 1))
            started_jobs=$((started_jobs + 1))
            # Update header with next-in-queue hint
            local next_file=""
            if (( started_jobs < total_files )); then
                next_file="${convlist[started_jobs]}"
            fi
            printf "TOTAL=%d\nSTARTED=%d\nPROCESSED=%d\nSKIPPED=%d\nACTIVE=%d\nNEXT=%s\n" \
                "$total_files" "$started_jobs" "$processed_files" "$skipped_files" "$active_jobs" "$next_file" > "$parallel_log_dir/queue_status"
        done
        
        # Wait for all remaining jobs to complete (ignore empty slots)
        for pid in "${job_pids[@]}"; do
            [[ -n "$pid" ]] || continue
            wait "$pid"  # Just wait, don't increment here - counts are in temp files
        done
        
        # Get final counts from temp files
        processed_files=$(wc -l < "$parallel_log_dir/processed_count.tmp" 2>/dev/null || echo 0)
        skipped_files=$(wc -l < "$parallel_log_dir/skipped_count.tmp" 2>/dev/null || echo 0)
        
        # Collect missing files from parallel processing
        if [[ -f "$parallel_log_dir/missing_files.tmp" ]]; then
            while IFS= read -r missing_file; do
                missing_files_list+=("$missing_file")
            done < "$parallel_log_dir/missing_files.tmp"
            missing_files=${#missing_files_list[@]}
        fi

        # Stop parallel display and clear signal trap (also kills refresher)
        stop_parallel_display
        trap - INT TERM
        
    else
        # SEQUENTIAL PROCESSING MODE (original logic)
        for ((i=0; i<total_files; i++)); do
            # Check for interrupt signal to exit entire queue
            if [[ $should_exit_queue == true ]]; then
                printf "\n\033[33mExiting queue processing as requested...\033[0m\n"
                break
            fi
            
            current_file="${convlist[i]}"
            
            # Check if file still exists before processing
            if [[ ! -f "$current_file" ]]; then
                log "WARNING: File disappeared from queue: $current_file" "31" true
                notify "Missing File Warning" "File disappeared from queue: $(basename "$current_file")"
                printf '\a'  # Terminal bell
                missing_files_list+=("$current_file")
                missing_files=$((missing_files + 1))
                skipped_files=$((skipped_files + 1))
                continue
            fi
            
            log "Starting to process file $((i+1))/$total_files: $current_file" "34" true
            result=0
            encode_single_file "${convlist[i]}" || result=$?

            if [[ $result -eq 1 ]]; then
                log "SKIPPED: File missing or unreadable: ${convlist[i]}" "33" true
                skipped_files=$((skipped_files + 1))
                # Still show progress
                display_encode_progress "$total_files" "$processed_files" "$skipped_files"
                echo  # New line after progress
            elif [[ $result -eq 2 ]]; then
                log "SKIPPED: Dolby Vision unsupported/disabled: ${convlist[i]}" "33" true
                # Note: skipped_files is already incremented in encode_single_file
            elif [[ $result -eq 3 ]]; then
                log "REVERTED: AV1 file was larger than original: ${convlist[i]}" "33" true
                # Note: skipped_files is already incremented in encode_single_file for reverted files
            else
                log "Successfully completed processing file: ${convlist[i]}" "32" true
                processed_files=$((processed_files + 1))
            fi
        
            # Display progress AFTER processing each file
            display_encode_progress "$total_files" "$processed_files" "$skipped_files"
            
            # Only add newline if not the last file
            if [[ $i -lt $((total_files - 1)) ]]; then
                echo  # Move to next line for next file's output
                echo  # Extra line for readability
            fi
        done
    fi

    # Final summary (cursor should be on the progress line)
    # In parallel mode, reconstruct totals from tracker files to avoid subshell loss
    if [[ $max_parallel_jobs -gt 1 ]]; then
        local pdir="$temp_dir/parallel_logs"
        if [[ -f "$pdir/originals.lines" ]]; then
            total_original_bytes=$(awk '{s+=$1} END{printf "%d", s}' "$pdir/originals.lines" 2>/dev/null || echo 0)
        fi
        if [[ -f "$pdir/finals.lines" ]]; then
            total_final_bytes=$(awk '{s+=$1} END{printf "%d", s}' "$pdir/finals.lines" 2>/dev/null || echo 0)
        fi
        if [[ -f "$pdir/savings.lines" ]]; then
            total_space_saved=$(awk '{s+=$1} END{printf "%d", s}' "$pdir/savings.lines" 2>/dev/null || echo 0)
        fi
    fi
    echo  # New line after final progress
    echo  # Extra line before summary
    log "All files processed." "32" true
    log "Total files processed: $processed_files" "32" true
    log "Total Dolby Vision skips (unsupported/disabled): $skipped_files" "33" true
    
    # Report missing files if any
    if [[ $missing_files -gt 0 ]]; then
        log "Files disappeared from queue: $missing_files" "31" true
        log "Missing files list:" "31" true
        for missing_file in "${missing_files_list[@]}"; do
            log "  - $missing_file" "31" true
        done
    fi

    # Format the total space change properly
    local total_space_summary=""
    if [[ $total_space_saved -gt 0 ]]; then
        total_space_summary=$(numfmt --to=iec --format="%.2f" "$total_space_saved")
        log "Total space saved: $total_space_summary" "32" true
    elif [[ $total_space_saved -lt 0 ]]; then
        local abs_total=$((total_space_saved * -1))
        total_space_summary=$(numfmt --to=iec --format="%.2f" "$abs_total")
        log "Total size increase: +$total_space_summary" "33" true
    else
        log "Total space change: 0.00" "32" true
    fi

    # Calculate overall processing time and display batch summary
    local overall_duration=$((SECONDS - overall_start_time))
    display_batch_summary "$processed_files" "$skipped_files" "$overall_duration"
}

# ============================================================================
# SCRIPT EXECUTION
# ============================================================================

# Call main function - let's make some AV1 magic!
main "$@"
