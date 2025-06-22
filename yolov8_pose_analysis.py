import os
import sys
from pathlib import Path
from ultralytics import YOLO
import argparse
import cv2
import pandas as pd
import math
from datetime import datetime
import matplotlib.pyplot as plt

def extract_pose_data(results, filename):
    pose_entries = []
    for r in results:
        keypoints = r.keypoints
        if keypoints is None:
            continue
        for idx, kp_set in enumerate(keypoints.xy):
            for i, (x, y) in enumerate(kp_set):
                conf = keypoints.conf[idx][i].item()
                pose_entries.append({
                    "file": filename,
                    "person_id": idx,
                    "keypoint_index": i,
                    "x": round(x.item(), 2),
                    "y": round(y.item(), 2),
                    "confidence": round(conf, 3)
                })
    return pose_entries

def draw_pose_overlay(image_path, pose_data, output_path):
    POSE_CONNECTIONS = [
        (0, 1), (0, 2), (1, 3), (2, 4),
        (5, 6), (5, 7), (7, 9), (6, 8), (8, 10),
        (5, 11), (6, 12), (11, 12),
        (11, 13), (13, 15), (12, 14), (14, 16)
    ]

    ANGLE_TRIPLETS = [
        (5, 7, 9),   # left shoulder - elbow - wrist
        (6, 8, 10),  # right shoulder - elbow - wrist
        (11, 13, 15), # left hip - knee - ankle
        (12, 14, 16)  # right hip - knee - ankle
    ]

    img = cv2.imread(str(image_path))
    if img is None:
        return

    grouped = pose_data.groupby("person_id")

    for person_id, group in grouped:
        keypoints = {int(row["keypoint_index"]): (int(row["x"]), int(row["y"]), row["confidence"])
                     for _, row in group.iterrows() if row["confidence"] > 0.3}

        for kp_idx, (x, y, conf) in keypoints.items():
            color = (0, int(conf * 255), int((1 - conf) * 255))  # green to red
            cv2.circle(img, (x, y), 5, color, -1)
            cv2.putText(img, str(kp_idx), (x + 5, y - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.4, color, 1)

        for pt1, pt2 in POSE_CONNECTIONS:
            if pt1 in keypoints and pt2 in keypoints:
                x1, y1, _ = keypoints[pt1]
                x2, y2, _ = keypoints[pt2]
                cv2.line(img, (x1, y1), (x2, y2), (255, 255, 0), 2)

        for a, b, c in ANGLE_TRIPLETS:
            if a in keypoints and b in keypoints and c in keypoints:
                angle = calculate_angle(keypoints[a][:2], keypoints[b][:2], keypoints[c][:2])
                bx, by, _ = keypoints[b]
                cv2.putText(img, f"{int(angle)}°", (bx - 10, by - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 255), 1)

    os.makedirs(output_path.parent, exist_ok=True)
    cv2.imwrite(str(output_path), img)

def calculate_angle(a, b, c):
    ba = (a[0] - b[0], a[1] - b[1])
    bc = (c[0] - b[0], c[1] - b[1])
    dot_product = ba[0]*bc[0] + ba[1]*bc[1]
    magnitude_ba = math.sqrt(ba[0]**2 + ba[1]**2)
    magnitude_bc = math.sqrt(bc[0]**2 + bc[1]**2)
    if magnitude_ba * magnitude_bc == 0:
        return 0
    angle_rad = math.acos(max(min(dot_product / (magnitude_ba * magnitude_bc), 1.0), -1.0))
    return math.degrees(angle_rad)

def compute_pose_score(df):
    scores = []
    grouped = df.groupby(["file", "person_id"])
    for (file, pid), group in grouped:
        valid_points = group[group["confidence"] > 0.3]
        total_points = 17
        score = len(valid_points) / total_points
        avg_conf = valid_points["confidence"].mean() if not valid_points.empty else 0
        scores.append({
            "file": file,
            "person_id": pid,
            "pose_score": round(score * avg_conf, 3),
            "avg_confidence": round(avg_conf, 3),
            "detected_keypoints": len(valid_points)
        })
    return pd.DataFrame(scores)

def plot_pose_scores(df, output_path):
    plt.figure(figsize=(10, 6))
    for file, group in df.groupby("file"):
        plt.plot(group["person_id"], group["pose_score"], label=file)
    plt.xlabel("Person ID")
    plt.ylabel("Pose Score")
    plt.title("Pose Quality Scores")
    plt.legend()
    plt.tight_layout()
    plt.savefig(output_path)
    print(f"\n📊 Pose score chart saved to {output_path}")

def save_top_n_poses(df, n=1):
    top_n = df.sort_values(by=["file", "pose_score"], ascending=[True, False])
    top_n = top_n.groupby("file").head(n)
    top_n_file = Path("yolo_output/top_n_pose_scores.xlsx")
    top_n.to_excel(top_n_file, index=False)
    print(f"✅ Top-N pose scores saved to {top_n_file}")

def process_source(model, source_path: Path, results_list, overlay_dir: Path):
    if source_path.suffix.lower() in [".mp4", ".avi", ".mov"]:
        results = model.predict(source=str(source_path), stream=True)
        for frame_id, r in enumerate(results):
            frame_pose = extract_pose_data([r], f"{source_path.name}_frame_{frame_id}")
            results_list.extend(frame_pose)
    else:
        results = model.predict(source=str(source_path))
        pose_data = extract_pose_data(results, source_path.name)
        results_list.extend(pose_data)
        if pose_data:
            df = pd.DataFrame(pose_data)
            overlay_path = overlay_dir / source_path.name
            draw_pose_overlay(source_path, df, overlay_path)

def main():
    parser = argparse.ArgumentParser(description="YOLOv8 Pose Estimation Batch Tool")
    parser.add_argument('--folder', type=str, required=True, help="Folder with images and/or videos")
    parser.add_argument('--model', type=str, default="yolov8s-pose.pt", help="YOLOv8 pose model")
    parser.add_argument('--topn', type=int, default=1, help="Top-N poses to save per file")
    args = parser.parse_args()

    input_dir = Path(args.folder)
    if not input_dir.is_dir():
        print(f"Error: {input_dir} is not a directory")
        sys.exit(1)

    model = YOLO(args.model)
    results_list = []
    overlay_dir = Path("yolo_output/pose_overlay")
    overlay_dir.mkdir(parents=True, exist_ok=True)

    for file_path in input_dir.iterdir():
        if file_path.suffix.lower() in [".jpg", ".jpeg", ".png", ".mp4", ".avi", ".mov"]:
            print(f"Processing: {file_path.name}")
            process_source(model, file_path, results_list, overlay_dir)

    if results_list:
        df = pd.DataFrame(results_list)
        output_file = Path("yolo_output/pose_analysis_results.xlsx")
        score_file = Path("yolo_output/pose_scores.xlsx")
        chart_file = Path("yolo_output/pose_score_chart.png")
        output_file.parent.mkdir(parents=True, exist_ok=True)
        df.to_excel(output_file, index=False)
        score_df = compute_pose_score(df)
        score_df.to_excel(score_file, index=False)
        # plot_pose_scores(score_df, chart_file)
        save_top_n_poses(score_df, n=args.topn)
        print(f"\n✅ Pose analysis saved to {output_file}")
        print(f"✅ Pose scores saved to {score_file}")
    else:
        print("\nNo pose data found.")

if __name__ == "__main__":
    main()
