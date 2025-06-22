import sys
import os
from ultralytics import YOLO
from pathlib import Path
import shutil

def delete_cache(paths):
    for path in paths:
        if os.path.isfile(path):
            os.remove(path)
        elif os.path.isdir(path):
            shutil.rmtree(path)

def main():
    if len(sys.argv) < 2:
        print("Usage: python detect_yolov8.py <image_path>")
        sys.exit(1)

    input_path = Path(sys.argv[1])
    if not input_path.is_file():
        print(f"Error: {input_path} does not exist.")
        sys.exit(1)

    # Model setup
    model = YOLO("yolov8s.pt")  # Use yolov8s.pt, yolov8m.pt for higher accuracy

    # Output paths
    output_dir = input_path.parent / "yolo_output"
    output_image = output_dir / f"{input_path.stem}_detected.jpg"
    output_dir.mkdir(exist_ok=True)

    # Clean previous outputs
    delete_cache([output_image])

    # Inference
    results = model.predict(
        source=str(input_path),
        save=True,
        project=str(output_dir),
        name="",  # Save image directly in `output_dir`
        exist_ok=True
    )

    # Process results
    for r in results:
        print(f"\nDetected {len(r.boxes)} object(s):")
        for box in r.boxes:
            cls_id = int(box.cls)
            cls_name = model.names[cls_id]
            conf = box.conf.item()
            xyxy = box.xyxy.tolist()[0]
            print(f"{cls_name} ({conf*100:.2f}%) - Box: {xyxy}")

if __name__ == "__main__":
    main()
