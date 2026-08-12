from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from Scripts.analyze_research_exports import (
    analyze_export,
    analyze_exports,
    expand_input_paths,
    render_markdown,
)


class AnalyzeResearchExportsTests(unittest.TestCase):
    def write_export(self, root: Path, name: str, manifest: dict, samples: list[dict]) -> Path:
        path = root / name
        header = {
            "recordType": "badminton_research_capture_header",
            "formatVersion": 1,
            "exportedAt": "2026-08-12T12:00:00Z",
            "manifest": manifest,
            "participant": None,
        }
        with path.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(header) + "\n")
            for sample in samples:
                handle.write(json.dumps(sample) + "\n")
        return path

    def manifest(self, capture_id: str, sample_count: int) -> dict:
        return {
            "schemaVersion": 3,
            "id": capture_id,
            "mode": "single_action",
            "manualLabel": "smash",
            "provenance": "physical_sensor",
            "reviewStatus": "valid",
            "sampleCount": sample_count,
            "quality": {
                "abnormalIntervalCount": 0,
                "suspectedDroppedSampleCount": 0,
                "suspectedSaturationSampleCount": 0,
            },
        }

    def test_valid_export_is_streamed_into_per_source_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self.write_export(
                root,
                "valid.badminton-ndjson",
                self.manifest("capture-1", 3),
                [
                    {
                        "sequenceNumber": 0,
                        "source": "accelerometer",
                        "monotonicTimestampSeconds": 100.0,
                        "elapsedTimeSeconds": 0.0,
                        "accelerationMetersPerSecondSquared": {"x": 1, "y": 2, "z": 3},
                    },
                    {
                        "sequenceNumber": 1,
                        "source": "accelerometer",
                        "monotonicTimestampSeconds": 100.01,
                        "elapsedTimeSeconds": 0.01,
                        "actualIntervalSeconds": 0.01,
                        "accelerationMetersPerSecondSquared": {"x": 2, "y": 3, "z": 4},
                    },
                    {
                        "sequenceNumber": 2,
                        "source": "gyroscope",
                        "monotonicTimestampSeconds": 100.02,
                        "elapsedTimeSeconds": 0.005,
                        "angularVelocityRadiansPerSecond": {"x": 4, "y": 5, "z": 6},
                    },
                ],
            )

            result = analyze_export(path)

            self.assertTrue(result["structural_integrity"])
            self.assertEqual(result["errors"], [])
            self.assertEqual(result["observed_sample_count"], 3)
            self.assertEqual(result["sources"]["accelerometer"]["sample_count"], 2)
            self.assertAlmostEqual(
                result["sources"]["accelerometer"]["timestamp_delta"]["mean_seconds"],
                0.01,
            )
            self.assertEqual(result["quality_gate_decision"], "not_evaluated")

    def test_mismatched_count_and_non_monotonic_source_are_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self.write_export(
                root,
                "invalid.badminton-ndjson",
                self.manifest("capture-2", 3),
                [
                    {
                        "sequenceNumber": 0,
                        "source": "accelerometer",
                        "monotonicTimestampSeconds": 10.0,
                        "elapsedTimeSeconds": 0.0,
                        "accelerationMetersPerSecondSquared": {"x": 1, "y": 2, "z": 3},
                    },
                    {
                        "sequenceNumber": 1,
                        "source": "accelerometer",
                        "monotonicTimestampSeconds": 9.0,
                        "elapsedTimeSeconds": 0.01,
                        "accelerationMetersPerSecondSquared": {"x": 1, "y": 2, "z": 3},
                    },
                ],
            )

            result = analyze_export(path)

            self.assertFalse(result["structural_integrity"])
            self.assertTrue(any(error.startswith("sample_count_mismatch") for error in result["errors"]))
            self.assertTrue(any(error.startswith("non_monotonic_timestamp") for error in result["errors"]))

    def test_batch_totals_do_not_claim_a_quality_gate_decision(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = [
                self.write_export(
                    root,
                    f"capture-{index}.badminton-ndjson",
                    self.manifest(f"capture-{index}", 0),
                    [],
                )
                for index in range(2)
            ]

            report = analyze_exports(paths)

            self.assertEqual(report["totals"]["capture_count"], 2)
            self.assertEqual(report["totals"]["structurally_valid_capture_count"], 2)
            self.assertEqual(report["quality_gate_decision"], "not_evaluated")
            self.assertEqual(expand_input_paths([root]), sorted(paths))

            markdown = render_markdown(report)
            self.assertIn("质量门禁：`未评估 (not_evaluated)`", markdown)
            self.assertIn("不代表真机数据质量门禁通过", markdown)
            self.assertNotIn("质量门禁：通过", markdown)


if __name__ == "__main__":
    unittest.main()
