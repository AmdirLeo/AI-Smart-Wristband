"""Build the four runtime demo records from held-out public UMAFall trials."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

import joblib
import numpy as np

try:
    from .pipeline import (DATA_MD5, DATA_PAGE, DataQualityError, align_streams,
                           dataset_zip, md5_file, parse_umafall, predict_streams, trial_metadata)
except ImportError:
    from pipeline import (DATA_MD5, DATA_PAGE, DataQualityError, align_streams,
                          dataset_zip, md5_file, parse_umafall, predict_streams, trial_metadata)

ROOT = Path(__file__).resolve().parent
CATEGORIES = {
    (0, 0): ("normal", "日常动作 · 正确识别"),
    (1, 1): ("fall", "模拟跌倒 · 正确识别"),
    (0, 1): ("false_positive", "误报示例 · 日常动作"),
    (1, 0): ("false_negative", "漏检示例 · 模拟跌倒"),
}


def prepare(data_path: Path, model_path: Path, output: Path):
    if md5_file(data_path) != DATA_MD5:
        raise ValueError("Wrong UMAFall ZIP checksum")
    artifact = joblib.load(model_path)
    test_subjects = set(artifact["report"]["protocol"]["test_subjects"])
    chosen = {}
    with zipfile.ZipFile(data_path) as archive:
        for name in sorted(archive.namelist()):
            if not name.lower().endswith(".csv") or name.startswith("__MACOSX"):
                continue
            meta = trial_metadata(name)
            if meta["subject"] not in test_subjects:
                continue
            try:
                a, g = align_streams(*parse_umafall(archive.read(name).decode("utf-8-sig")))
                t = np.arange(len(a)) / artifact["sampling_hz"]
                rows = np.round(np.column_stack([t, a, g]), 9)
                result = predict_streams(artifact, rows[:, :4], rows[:, [0, 4, 5, 6]])
            except DataQualityError:
                continue
            category = (meta["label"], int(result["label"] == "suspected_fall"))
            if category in chosen:
                continue
            key, title = CATEGORIES[category]
            chosen[category] = {"id": key, "title": title, "subject": meta["subject"],
                                "activity": meta["activity"], "source_file": name,
                                "true_label": meta["label"], "expected_label": result["label"],
                                "duration_s": float(t[-1]), "samples": rows.tolist()}
            if len(chosen) == 4:
                break
    if len(chosen) != 4:
        raise ValueError("Held-out trials do not cover all four outcomes; revise demo selection explicitly")
    bundle = {"source": DATA_PAGE, "license": "CC BY 4.0",
              "attribution": "Eduardo Casilari; Jose A. Santoyo-Ramón; UMAFall v8",
              "transformation": "wrist accel/gyro only; aligned to 20 Hz; timestamps relative; rounded to 9 decimals",
              "selection": "first sorted held-out example of each confusion-matrix category; illustrative, not prevalence",
              "model_sha256": hashlib.sha256(model_path.read_bytes()).hexdigest(),
              "records": [chosen[k] for k in CATEGORIES]}
    output.write_text(json.dumps(bundle, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(json.dumps({"records": [{k: v for k, v in r.items() if k != "samples"}
                                  for r in bundle["records"]]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-zip")
    parser.add_argument("--model", type=Path, default=ROOT / "model.joblib")
    parser.add_argument("--output", type=Path, default=ROOT / "demo_samples.json")
    args = parser.parse_args()
    with dataset_zip(args.data_zip) as data:
        prepare(data, args.model, args.output)
