#!/usr/bin/env python
from __future__ import (absolute_import, division, print_function, unicode_literals)
import os, glob, subprocess
from pathlib import Path

# Video extensions to include
FILE_SUGGESTIONS = ['mpg', 'avi', 'mp4', 'flv', '3gp', 'wmv', 'vob', 'webm', 'mts', 'mkv', 'ts']
FFMPEG = "ffmpeg -hide_banner -loglevel error"

def runprogram(command):
    with open("stdout.log", "a") as fout, open("stderr.log", "a") as ferr:
        return subprocess.call(command, shell=True, stdout=fout, stderr=ferr)

def delFile(file):
    try:
        os.unlink(file)
    except Exception:
        pass

if __name__ == '__main__':
    os.makedirs("output", exist_ok=True)
    os.makedirs("over", exist_ok=True)

    delFile("output.ts")
    delFile("output.mp4")
    delFile("join.txt")

    ts_full_file_list = []

    # Convert all supported videos to .ts
    for filename in sorted(glob.glob("*.*")):
        extension = Path(filename).suffix[1:].lower()
        if extension in FILE_SUGGESTIONS:
            base = Path(filename).stem
            ts_file = f"{base}.ts"
            print(f"Converting: {filename} -> {ts_file}")
            # cmd = f'{FFMPEG} -i "{filename}" -c:v libx264 -preset veryfast -crf 23 -c:a aac -f mpegts "{ts_file}"'
            cmd = f'{FFMPEG} -i "{filename}" -c:v mpeg2video -q:v 5 -c:a mp2 -b:a 192k "{ts_file}"'

            runprogram(cmd)
            ts_full_file_list.append(ts_file)

    # Create concat file
    with open("join.txt", "w") as f:
        for ts_file in ts_full_file_list:
            f.write(f"file '{ts_file}'\n")

    # Merge into output.mp4
    print("Merging all .ts files into output.mp4")
    merge_cmd = f'{FFMPEG} -f concat -safe 0 -i join.txt -c copy output/output.mp4'
    runprogram(merge_cmd)

    # Optional: move originals to "over" folder
    for f in ts_full_file_list:
        delFile(f)

    delFile("join.txt")
    print("Done.")
