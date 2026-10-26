"""Reproducible, wrist-only UMAFall random-forest baseline.

The prediction unit is a complete, approximately 15-second labeled trial.
This is NOT an online fall-onset detector or a validated medical device.
Only the requested model artifact is saved; downloads use temporary storage.
"""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import tempfile
import zipfile

import joblib
import numpy as np
import pandas as pd
import requests
from scipy.signal import butter, sosfiltfilt
from sklearn import __version__ as sklearn_version
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.metrics import (
    average_precision_score, confusion_matrix, precision_recall_fscore_support,
    roc_auc_score,
)
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.pipeline import make_pipeline

DATA_URL = "https://ndownloader.figshare.com/files/43076140"
DATA_MD5 = "40055f4b09a29c35a8c8705b1a92c6b8"
DATA_PAGE = "https://figshare.com/articles/dataset/UMA_ADL_FALL_Dataset_zip/4214283"
SAMPLE_HZ = 20
MIN_SECONDS = 10.0
MAX_SECONDS = 20.0
MAX_GAP_SECONDS = 0.75
CSV_COLUMNS = ("timestamp_s", "ax_g", "ay_g", "az_g", "gx_dps", "gy_dps", "gz_dps")
NAME_PATTERN = re.compile(
    r"UMAFall_Subject_(\d+)_(ADL|Fall)_([^/]+)_(\d+)_\d{4}-\d{2}-\d{2}_", re.I
)


class DataQualityError(ValueError):
    """A recording cannot be used without inventing missing sensor data."""


@contextmanager
def dataset_zip(local_path: str | None):
    if local_path:
        yield Path(local_path)
        return
    with tempfile.TemporaryDirectory(prefix="umafall_") as tmp:
        target = Path(tmp) / "UMAFall_corrected.zip"
        with requests.get(DATA_URL, stream=True, timeout=(20, 120)) as response:
            response.raise_for_status()
            with target.open("wb") as output:
                for chunk in response.iter_content(1024 * 1024):
                    output.write(chunk)
        yield target


def md5_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "md5").hexdigest()


def trial_metadata(filename: str) -> dict:
    match = NAME_PATTERN.search(Path(filename).name)
    if not match:
        raise DataQualityError("unrecognized UMAFall filename")
    subject, category, activity, repetition = match.groups()
    return {"subject": int(subject), "label": int(category.lower() == "fall"),
            "activity": activity, "trial": int(repetition), "file": filename}


def parse_umafall(text: str) -> tuple[np.ndarray, np.ndarray]:
    """Return wrist acceleration and gyro as [seconds, x, y, z].

    UMAFall SensorTag values use g and degrees/second. The wrist sensor ID is
    read separately from EACH file header; it is not assumed to be constant.
    """
    wrist_ids = []
    for line in text.splitlines():
        if line.lstrip().startswith("%"):
            parts = [p.strip() for p in line.lstrip().lstrip("%").split(";")]
            if len(parts) >= 3 and parts[2].upper() == "WRIST":
                wrist_ids.append(int(parts[1]))
    if len(set(wrist_ids)) != 1:
        raise DataQualityError("missing or ambiguous WRIST sensor mapping")
    wrist_id = wrist_ids[0]
    channels: dict[int, list] = {0: [], 1: []}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("%"):
            continue
        fields = line.strip().rstrip(";").split(";")
        if len(fields) != 7:
            raise DataQualityError("malformed sensor row")
        try:
            kind, sensor = int(fields[5]), int(fields[6])
            if sensor == wrist_id and kind in channels:
                channels[kind].append([float(fields[0]) / 1000,
                                       *map(float, fields[2:5])])
        except ValueError as exc:
            raise DataQualityError("invalid numeric sensor field") from exc
    if any(not channels[k] for k in channels):
        raise DataQualityError("wrist acceleration or gyro missing")
    return np.asarray(channels[0]), np.asarray(channels[1])


def clean_stream(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=float)
    if values.ndim != 2 or values.shape[1] != 4 or len(values) < 3:
        raise DataQualityError("sensor stream must contain time and three axes")
    if not np.isfinite(values).all():
        raise DataQualityError("non-finite sensor values")
    values = values[np.argsort(values[:, 0], kind="stable")]
    timestamps, inverse, counts = np.unique(values[:, 0], return_inverse=True, return_counts=True)
    summed = np.zeros((len(timestamps), 3))
    np.add.at(summed, inverse, values[:, 1:])
    values = np.column_stack([timestamps, summed / counts[:, None]])
    if len(values) < 3 or np.max(np.diff(timestamps)) > MAX_GAP_SECONDS:
        raise DataQualityError("too few samples or a sensor gap exceeding 0.75 seconds")
    duration = timestamps[-1] - timestamps[0]
    if duration <= 0 or (len(timestamps) - 1) / duration < SAMPLE_HZ * 0.7:
        raise DataQualityError("effective sampling rate below 14 Hz")
    return values


def interpolate_stream(stream: np.ndarray, target_time: np.ndarray) -> np.ndarray:
    """Resample to 20 Hz; filter higher-rate input before downsampling."""
    timestamp, axes = stream[:, 0], stream[:, 1:]
    source_hz = (len(timestamp) - 1) / (timestamp[-1] - timestamp[0])
    if source_hz > SAMPLE_HZ * 1.25:
        uniform_time = np.linspace(timestamp[0], timestamp[-1], len(timestamp))
        uniform = np.column_stack([np.interp(uniform_time, timestamp, axes[:, j]) for j in range(3)])
        filt = butter(4, SAMPLE_HZ * 0.4, fs=source_hz, output="sos")
        axes = sosfiltfilt(filt, uniform, axis=0)
        timestamp = uniform_time
    return np.column_stack([np.interp(target_time, timestamp, axes[:, j]) for j in range(3)])


def align_streams(acc: np.ndarray, gyro: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    acc, gyro = clean_stream(acc), clean_stream(gyro)
    start, end = max(acc[0, 0], gyro[0, 0]), min(acc[-1, 0], gyro[-1, 0])
    duration = end - start
    if not MIN_SECONDS <= duration <= MAX_SECONDS:
        raise DataQualityError(f"shared duration {duration:.2f}s outside 10–20s trial range")
    grid = start + np.arange(int(np.floor(duration * SAMPLE_HZ)) + 1) / SAMPLE_HZ
    return interpolate_stream(acc, grid), interpolate_stream(gyro, grid)


def extract_features(acc: np.ndarray, gyro: np.ndarray) -> dict[str, float]:
    """Features of complete trials, not labels or subject demographics.

    Magnitudes and relative orientation reduce dependence on board axes.
    Post-peak quantities are retrospective and cannot predict before impact.
    The orientation proxy is only used when both endpoint segments are quiet.
    """
    if acc.shape != gyro.shape or acc.ndim != 2 or acc.shape[1] != 3 or len(acc) < 3 * SAMPLE_HZ:
        raise DataQualityError("aligned arrays must be matching N×3 streams")
    if not np.isfinite(acc).all() or not np.isfinite(gyro).all():
        raise DataQualityError("non-finite feature input")
    a, g = np.linalg.norm(acc, axis=1), np.linalg.norm(gyro, axis=1)
    jerk = np.linalg.norm(np.diff(acc, axis=0), axis=1) * SAMPLE_HZ
    result: dict[str, float] = {}
    for name, values in [("acc", a), ("gyro", g), ("jerk", jerk)]:
        result[name + "_mean"] = float(np.mean(values))
        result[name + "_std"] = float(np.std(values))
        result[name + "_min"] = float(np.min(values))
        result[name + "_max"] = float(np.max(values))
        for percentile in [10, 25, 50, 75, 90, 95]:
            result[f"{name}_p{percentile}"] = float(np.percentile(values, percentile))
    result["dynamic_acc_mean"] = float(np.mean(np.abs(a - 1)))
    result["dynamic_acc_p95"] = float(np.percentile(np.abs(a - 1), 95))
    # Thresholds here define interpretable features; they are not fall labels.
    result["high_acc_fraction"] = float(np.mean(a > 2))
    result["low_acc_fraction"] = float(np.mean(a < 0.5))
    result["fast_rotation_fraction"] = float(np.mean(g > 100))
    half_second = SAMPLE_HZ // 2
    local_std = pd.Series(a).rolling(half_second, min_periods=half_second).std(ddof=0).to_numpy()
    still = (np.abs(a - 1) < 0.15) & (g < 10) & (local_std < 0.08)
    longest = current = 0
    for quiet in still:
        current = current + 1 if quiet else 0
        longest = max(longest, current)
    result["still_fraction"] = float(still.mean())
    result["longest_still_seconds"] = longest / SAMPLE_HZ
    tail = 2 * SAMPLE_HZ
    result["ending_acc_std"] = float(a[-tail:].std())
    result["ending_gyro_mean"] = float(g[-tail:].mean())
    result["ending_still_fraction"] = float(still[-tail:].mean())
    peak = int(np.argmax(a))
    pre = slice(max(0, peak - tail), peak)
    post = slice(peak + half_second, min(len(a), peak + half_second + tail))
    for name, segment in [("pre_peak", pre), ("post_peak", post)]:
        enough = len(a[segment]) >= SAMPLE_HZ
        result[name + "_acc_std"] = float(a[segment].std()) if enough else np.nan
        result[name + "_gyro_mean"] = float(g[segment].mean()) if enough else np.nan
    first, last = acc[:SAMPLE_HZ].mean(axis=0), acc[-SAMPLE_HZ:].mean(axis=0)
    quiet_ends = (a[:SAMPLE_HZ].std() < 0.15 and a[-SAMPLE_HZ:].std() < 0.15
                  and g[:SAMPLE_HZ].mean() < 20 and g[-SAMPLE_HZ:].mean() < 20)
    denominator = np.linalg.norm(first) * np.linalg.norm(last)
    result["settled_orientation_change_deg"] = (
        float(np.degrees(np.arccos(np.clip(first @ last / denominator, -1, 1))))
        if quiet_ends and denominator > 1e-8 else np.nan
    )
    return result


def load_dataset(path: Path) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    if md5_file(path) != DATA_MD5:
        raise ValueError("Dataset checksum mismatch: use the specified corrected UMAFall ZIP.")
    features, metadata, rejected = [], [], []
    fingerprints: dict[str, int] = {}
    with zipfile.ZipFile(path) as archive:
        names = sorted(n for n in archive.namelist() if n.lower().endswith(".csv") and not n.startswith("__MACOSX"))
        for name in names:
            try:
                meta = trial_metadata(name)
                raw = archive.read(name).decode("utf-8-sig")
                acc, gyro = align_streams(*parse_umafall(raw))
                key = hashlib.sha256(np.column_stack([acc, gyro]).tobytes()).hexdigest()
                if key in fingerprints:
                    if fingerprints[key] != meta["label"]:
                        raise ValueError("Identical signal has conflicting labels")
                    raise DataQualityError("duplicate sensor recording")
                fingerprints[key] = meta["label"]
                features.append(extract_features(acc, gyro)); metadata.append(meta)
            except DataQualityError as exc:
                rejected.append({"file": name, "reason": str(exc)})
    if not features:
        raise ValueError("No usable paired wrist recordings")
    X, meta = pd.DataFrame(features), pd.DataFrame(metadata)
    audit = {"source": DATA_PAGE, "download_url": DATA_URL, "md5": DATA_MD5,
             "license": "CC BY 4.0", "total_csv_files": len(names),
             "usable_trials": len(meta), "usable_subjects": sorted(meta.subject.unique().tolist()),
             "class_counts": {"non_fall": int((meta.label == 0).sum()), "fall": int(meta.label.sum())},
             "rejected_count": len(rejected), "rejection_reasons": dict(Counter(r["reason"] for r in rejected)),
             "rejected_files": rejected}
    return X, meta, audit


def make_estimator(seed: int):
    return make_pipeline(
        SimpleImputer(strategy="median", keep_empty_features=True),
        RandomForestClassifier(n_estimators=400, max_depth=12, min_samples_leaf=3,
                               max_features="sqrt", class_weight="balanced_subsample",
                               random_state=seed, n_jobs=2),
    )


def subject_split(y: np.ndarray, groups: np.ndarray, seed: int):
    if len(np.unique(groups)) < 8:
        raise ValueError("Need at least eight participants for this split protocol")
    cv = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=seed)
    dev, test = next(cv.split(np.zeros(len(y)), y, groups))
    assert not set(groups[dev]) & set(groups[test])
    if len(np.unique(y[test])) != 2 or len(np.unique(y[dev])) != 2:
        raise ValueError("Predefined subject split lacks a class; revise the protocol explicitly")
    return dev, test


def select_threshold(y: np.ndarray, scores: np.ndarray) -> tuple[float, float]:
    """Maximize development F2, favoring recall; never sees test labels."""
    candidates = np.unique(np.r_[0.0, scores, np.nextafter(float(scores.max()), np.inf)])
    best_key, best_threshold = (-1.0, -1.0, -1.0), 0.5
    for threshold in candidates:
        pred = scores >= threshold
        tp = int(np.sum((y == 1) & pred)); fn = int(np.sum((y == 1) & ~pred))
        fp = int(np.sum((y == 0) & pred))
        f2 = 5 * tp / (5 * tp + 4 * fn + fp) if tp + fn + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        key = (f2, recall, float(threshold))
        if key > best_key:best_key, best_threshold = key, float(threshold)
    return best_threshold, best_key[0]


def evaluate(y: np.ndarray, scores: np.ndarray, threshold: float) -> dict:
    pred = scores >= threshold
    tn, fp, fn, tp = confusion_matrix(y, pred, labels=[0, 1]).ravel()
    precision, recall, f1, _ = precision_recall_fscore_support(y, pred, average="binary", zero_division=0)
    return {"threshold": float(threshold), "trials": len(y),
            "confusion": {"TN": int(tn), "FP": int(fp), "FN": int(fn), "TP": int(tp)},
            "precision": float(precision), "recall": float(recall), "f1": float(f1),
            "f2": float(5 * tp / (5 * tp + 4 * fn + fp)) if 5 * tp + 4 * fn + fp else 0.0,
            "accuracy": float((tn + tp) / len(y)),
            "non_fall_trial_false_positive_rate": float(fp / (tn + fp)) if tn + fp else None,
            "roc_auc": float(roc_auc_score(y, scores)) if len(np.unique(y)) == 2 else None,
            "average_precision": float(average_precision_score(y, scores)) if len(np.unique(y)) == 2 else None}


def train(path: Path, output: Path, seed: int = 42) -> dict:
    X, meta, audit = load_dataset(path)
    y, groups = meta.label.to_numpy(), meta.subject.to_numpy()
    dev, test = subject_split(y, groups, seed)
    Xd, yd, gd = X.iloc[dev], y[dev], groups[dev]
    oof = np.full(len(dev), np.nan)
    fold_details = []
    cv = StratifiedGroupKFold(n_splits=4, shuffle=True, random_state=seed + 1)
    for fold, (tr, va) in enumerate(cv.split(Xd, yd, gd)):
        assert not set(gd[tr]) & set(gd[va])
        if len(np.unique(yd[tr])) != 2:
            raise ValueError("Inner training fold lacks a class")
        fitted = make_estimator(seed + fold).fit(Xd.iloc[tr], yd[tr])
        oof[va] = fitted.predict_proba(Xd.iloc[va])[:, 1]
        fold_details.append({"train_subjects": sorted(np.unique(gd[tr]).tolist()),
                             "validation_subjects": sorted(np.unique(gd[va]).tolist())})
    assert np.isfinite(oof).all()
    threshold, _ = select_threshold(yd, oof)
    rule_threshold, _ = select_threshold(yd, Xd.acc_max.to_numpy())
    estimator = make_estimator(seed).fit(Xd, yd)
    # The held-out set is first scored only after fitting and threshold selection.
    test_scores = estimator.predict_proba(X.iloc[test])[:, 1]
    predictions = (test_scores >= threshold).astype(int)
    # A large participant can occupy an entire outer fold. Evaluate EVERY fold,
    # with fresh inner threshold selection, instead of reporting just that person.
    outer_cv = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=seed)
    nested_predictions = np.full(len(y), -1, dtype=int)
    nested_rule_predictions = np.full(len(y), -1, dtype=int)
    outer_reports = []
    for outer_fold, (outer_dev, outer_test) in enumerate(outer_cv.split(X, y, groups)):
        if outer_fold == 0:
            np.testing.assert_array_equal(outer_dev, dev)
            np.testing.assert_array_equal(outer_test, test)
            outer_scores, outer_threshold = test_scores, threshold
            outer_rule_threshold = rule_threshold
        else:
            ox, oy, og = X.iloc[outer_dev], y[outer_dev], groups[outer_dev]
            inner_scores = np.full(len(outer_dev), np.nan)
            inner_cv = StratifiedGroupKFold(n_splits=4, shuffle=True, random_state=seed + 1)
            for inner_fold, (tr, va) in enumerate(inner_cv.split(ox, oy, og)):
                assert not set(og[tr]) & set(og[va])
                inner_model = make_estimator(seed + inner_fold).fit(ox.iloc[tr], oy[tr])
                inner_scores[va] = inner_model.predict_proba(ox.iloc[va])[:, 1]
            assert np.isfinite(inner_scores).all()
            outer_threshold, _ = select_threshold(oy, inner_scores)
            outer_rule_threshold, _ = select_threshold(oy, ox.acc_max.to_numpy())
            outer_model = make_estimator(seed).fit(ox, oy)
            outer_scores = outer_model.predict_proba(X.iloc[outer_test])[:, 1]
        assert not set(groups[outer_dev]) & set(groups[outer_test])
        assert (nested_predictions[outer_test] == -1).all()
        nested_predictions[outer_test] = outer_scores >= outer_threshold
        nested_rule_predictions[outer_test] = X.iloc[outer_test].acc_max.to_numpy() >= outer_rule_threshold
        outer_reports.append({"fold": outer_fold,
                              "test_subjects": sorted(set(groups[outer_test].tolist())),
                              "rf": evaluate(y[outer_test], outer_scores, outer_threshold),
                              "acceleration_rule": evaluate(y[outer_test], X.iloc[outer_test].acc_max.to_numpy(), outer_rule_threshold)})
    assert (nested_predictions >= 0).all() and (nested_rule_predictions >= 0).all()

    def pooled_metrics(pred):
        metrics = evaluate(y, pred.astype(float), 0.5)
        # Fold-specific thresholds yield binary pooled predictions, not a common
        # calibrated score. Do not manufacture a pooled ROC-AUC from those labels.
        for key in ["threshold", "roc_auc", "average_precision"]:
            metrics.pop(key)
        return metrics

    by_subject = {}
    for subject in sorted(set(groups[test])):
        mask = groups[test] == subject
        by_subject[str(subject)] = evaluate(y[test][mask], test_scores[mask], threshold)
    report = {
        "task": "retrospective classification of complete 10–20 second wrist trials",
        "seed": seed, "sklearn_version": sklearn_version, "features": list(X.columns),
        "dataset": audit,
        "protocol": {"outer": "first fold of 5-fold StratifiedGroupKFold; fixed before training",
                     "inner": "4-fold subject-disjoint OOF; fixed RF hyperparameters; F2 threshold selection",
                     "development_subjects": sorted(set(groups[dev].tolist())),
                     "test_subjects": sorted(set(groups[test].tolist())),
                     "development_trials": len(dev), "test_trials": len(test),
                     "inner_folds": fold_details},
        "development_oof_rf": evaluate(yd, oof, threshold),
        "test_rf": evaluate(y[test], test_scores, threshold),
        "test_acceleration_rule": evaluate(y[test], X.iloc[test].acc_max.to_numpy(), rule_threshold),
        "nested_subject_cv": {
            "protocol": "all five outer subject-disjoint folds; each threshold selected only inside its own development fold",
            "rf": pooled_metrics(nested_predictions),
            "acceleration_rule": pooled_metrics(nested_rule_predictions),
            "folds": outer_reports,
            "error_actions": dict(Counter(meta.iloc[i].activity for i in range(len(y)) if nested_predictions[i] != y[i])),
        },
        "test_by_subject": by_subject,
        "test_errors": [{**meta.iloc[idx].to_dict(), "score": float(score), "predicted": int(pred)}
                        for idx, score, pred in zip(test, test_scores, predictions) if pred != y[idx]],
        "top_feature_importances": sorted(
            zip(X.columns, estimator.named_steps["randomforestclassifier"].feature_importances_.tolist()),
            key=lambda pair: pair[1], reverse=True)[:12],
        "limits": ["Not a real-time onset detector; post-impact features use later samples.",
                   "Threshold tuned on development OOF; that OOF metric is not an untouched test estimate.",
                   "Scores are uncalibrated classifier scores, not clinical probabilities.",
                   "Trial false-positive rate is not false alarms per hour.",
                   "Subject-disjoint validation on this small simulated dataset cannot establish real-world elderly reliability.",
                   "No device-side firmware, BLE integration, or cloud API is implemented here."],
    }
    artifact = {"schema_version": 1, "estimator": estimator, "threshold": threshold,
                "feature_names": list(X.columns), "sampling_hz": SAMPLE_HZ,
                "input_columns": CSV_COLUMNS, "input_units": "seconds, g, degrees/second",
                "trial_seconds_range": [MIN_SECONDS, MAX_SECONDS], "report": report}
    output.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(artifact, output, compress=3)
    return report


def predict_streams(artifact: dict, acc: np.ndarray, gyro: np.ndarray) -> dict:
    a, g = align_streams(acc, gyro)
    feature = extract_features(a, g)
    frame = pd.DataFrame([feature], columns=artifact["feature_names"])
    score = float(artifact["estimator"].predict_proba(frame)[0, 1])
    threshold = float(artifact["threshold"])
    return {"label": "suspected_fall" if score >= threshold else "non_fall",
            "score": score, "threshold": threshold,
            "note": "Uncalibrated whole-trial score; not a real-time alarm decision."}


def predict_csv(model_path: Path, csv_path: Path) -> dict:
    # joblib/pickle may execute code: only load artifacts from trusted sources.
    artifact = joblib.load(model_path)
    frame = pd.read_csv(csv_path)
    if list(frame.columns) != list(CSV_COLUMNS):
        raise ValueError("CSV columns must be exactly: " + ",".join(CSV_COLUMNS))
    values = frame.to_numpy(dtype=float)
    return predict_streams(artifact, values[:, :4], values[:, [0, 4, 5, 6]])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("train", help="Download/validate UMAFall, train, and save one model artifact")
    p.add_argument("--data-zip", help="Existing corrected UMAFall ZIP; otherwise temporarily downloaded")
    p.add_argument("--output", type=Path, default=Path(__file__).parent / "model.joblib")
    p.add_argument("--seed", type=int, default=42)
    p = commands.add_parser("predict", help="Classify a 10–20 second CSV in the documented sensor units")
    p.add_argument("--model", type=Path, default=Path(__file__).parent / "model.joblib")
    p.add_argument("--csv", type=Path, required=True)
    p = commands.add_parser("inspect", help="Print the model's embedded training report")
    p.add_argument("--model", type=Path, default=Path(__file__).parent / "model.joblib")
    args = parser.parse_args()
    if args.command == "train":
        with dataset_zip(args.data_zip) as data:
            result = train(data, args.output, args.seed)
    elif args.command == "predict":
        result = predict_csv(args.model, args.csv)
    else:
        result = joblib.load(args.model)["report"]
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
