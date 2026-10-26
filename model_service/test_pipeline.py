"""Tests for sensor selection, data quality, leakage boundaries, and inference."""
import numpy as np
import pytest

from pipeline import (
    DataQualityError, align_streams, clean_stream, evaluate, extract_features,
    make_estimator, parse_umafall, select_threshold, subject_split, trial_metadata,
)


def test_reads_wrist_mapping_not_fixed_sensor_id():
    text = """% MAC Address; Sensor_ID; Position; Device Model
% AA:BB; 7; WRIST; SensorTag
% CC:DD; 3; WAIST; SensorTag
% TimeStamp; Sample No; X-Axis; Y-Axis; Z-Axis; Sensor Type; Sensor ID;
1000;1;0;0;1;0;7
1001;1;2;3;4;1;7
1002;1;90;90;90;0;3
1003;1;999;999;999;2;7
"""
    acc, gyro = parse_umafall(text)
    np.testing.assert_allclose(acc, [[1, 0, 0, 1]])
    np.testing.assert_allclose(gyro, [[1.001, 2, 3, 4]])


def test_missing_gyro_is_not_replaced_with_zero():
    with pytest.raises(DataQualityError, match="gyro missing"):
        parse_umafall("% A; 3; WRIST; SensorTag\n100;1;0;0;1;0;3")


def test_duplicate_timestamps_are_averaged_and_gap_rejected():
    raw = np.array([[.1, 3, 0, 0], [0, 1, 0, 0], [.05, 2, 0, 0], [.05, 4, 0, 0]])
    np.testing.assert_allclose(clean_stream(raw), [[0, 1, 0, 0], [.05, 3, 0, 0], [.1, 3, 0, 0]])
    raw[-1, 0] = 2
    with pytest.raises(DataQualityError, match="gap"):
        clean_stream(raw)


def test_stationary_gravity_is_one_g_not_zero():
    a = np.tile([0., 0., 1.], (300, 1));g = np.zeros_like(a)
    features = extract_features(a, g)
    assert features["acc_mean"] == 1
    assert features["dynamic_acc_mean"] == 0
    assert features["still_fraction"] > .9
    assert features["settled_orientation_change_deg"] == 0


def test_features_invariant_to_common_axis_rotation():
    rng = np.random.default_rng(4)
    a = rng.normal(0, .2, (300, 3)) + [0, 0, 1]
    g = rng.normal(0, 5, (300, 3))
    q, _ = np.linalg.qr(rng.normal(size=(3, 3)))
    original, rotated = extract_features(a, g), extract_features(a @ q, g @ q)
    np.testing.assert_allclose(list(original.values()), list(rotated.values()), equal_nan=True, atol=1e-9)


def test_resampling_rejects_short_records_and_suppresses_aliasing():
    t = np.arange(0, 15, 1 / 50)
    acc = np.column_stack([t, .1 * np.sin(2 * np.pi * 18 * t), np.zeros(len(t)), np.ones(len(t))])
    gyro = np.column_stack([t, np.zeros((len(t), 3))])
    a, g = align_streams(acc, gyro)
    assert a.shape == g.shape
    assert 295 <= len(a) <= 301
    assert np.std(a[20:-20, 0]) < .02
    with pytest.raises(DataQualityError, match="duration"):
        align_streams(acc[:100], gyro[:100])


def test_subject_split_never_shares_people():
    groups = np.repeat(np.arange(1, 21), 10)
    labels = np.tile([0] * 6 + [1] * 4, 20)
    dev, test = subject_split(labels, groups, 42)
    assert not set(groups[dev]) & set(groups[test])
    assert set(dev) | set(test) == set(range(len(labels)))
    np.testing.assert_array_equal(subject_split(labels, groups, 42)[1], test)


def test_label_and_activity_come_from_filename():
    meta = trial_metadata("UMAFall_Subject_03_Fall_BackwardFall_2_2016-06-02_11-20-30.csv")
    assert meta["subject"] == 3 and meta["label"] == 1 and meta["trial"] == 2
    assert meta["activity"] == "BackwardFall"


def test_threshold_and_metric_denominators():
    labels = np.array([0, 0, 1, 1])
    scores = np.array([.1, .2, .8, .9])
    threshold, f2 = select_threshold(labels, scores)
    assert .2 < threshold <= .8 and f2 == 1
    metrics = evaluate(labels, scores, .85)
    assert metrics["confusion"] == {"TN": 2, "FP": 0, "FN": 1, "TP": 1}
    assert metrics["recall"] == .5
    assert metrics["non_fall_trial_false_positive_rate"] == 0


def test_imputation_is_fitted_only_on_training_data():
    import pandas as pd
    X = pd.DataFrame({"f": [1., 3., np.nan, 5., 7., 9.], "empty": [np.nan] * 6})
    model = make_estimator(42).fit(X, [0, 0, 0, 1, 1, 1])
    assert model.named_steps["simpleimputer"].statistics_[0] == 5
    probabilities = model.predict_proba(pd.DataFrame({"f": [np.nan, 10000.], "empty": [np.nan, 1.]}))
    assert probabilities.shape == (2, 2)
    assert model.named_steps["simpleimputer"].statistics_[0] == 5
