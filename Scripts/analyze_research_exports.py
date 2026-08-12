#!/usr/bin/env python3
"""Stream-check BadmintonResearch NDJSON exports without running algorithms."""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


REPORT_FORMAT_VERSION = 1
EXPECTED_HEADER_TYPE = "badminton_research_capture_header"
SUPPORTED_EXPORT_FORMATS = {1}
SOURCES = ("accelerometer", "gyroscope", "device_motion")


def _is_finite_number(value: Any) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(value)
    )


def _new_source_summary() -> dict[str, Any]:
    return {
        "sample_count": 0,
        "payload_record_count": 0,
        "first_timestamp_seconds": None,
        "last_timestamp_seconds": None,
        "actual_interval": {
            "count": 0,
            "minimum_seconds": None,
            "mean_seconds": None,
            "maximum_seconds": None,
        },
        "timestamp_delta": {
            "count": 0,
            "minimum_seconds": None,
            "mean_seconds": None,
            "maximum_seconds": None,
        },
        "non_monotonic_timestamp_count": 0,
    }


def _update_interval(accumulator: dict[str, Any], value: Any) -> bool:
    if not _is_finite_number(value) or value < 0:
        return False
    accumulator["count"] += 1
    accumulator["sum"] = accumulator.get("sum", 0.0) + value
    current_minimum = accumulator["minimum_seconds"]
    accumulator["minimum_seconds"] = value if current_minimum is None else min(
        current_minimum, value
    )
    current_maximum = accumulator["maximum_seconds"]
    accumulator["maximum_seconds"] = value if current_maximum is None else max(
        current_maximum, value
    )
    return True


def _finish_interval(accumulator: dict[str, Any]) -> None:
    count = accumulator["count"]
    accumulator["mean_seconds"] = (
        accumulator.pop("sum", 0.0) / count if count else None
    )


def _has_expected_payload(source: str, sample: dict[str, Any]) -> bool:
    if source == "accelerometer":
        return sample.get("accelerationMetersPerSecondSquared") is not None
    if source == "gyroscope":
        return sample.get("angularVelocityRadiansPerSecond") is not None
    if source == "device_motion":
        return any(
            sample.get(field) is not None
            for field in (
                "angularVelocityRadiansPerSecond",
                "gravity",
                "userAccelerationMetersPerSecondSquared",
                "attitudeQuaternion",
            )
        )
    return False


def analyze_export(path: Path) -> dict[str, Any]:
    path = path.resolve()
    result: dict[str, Any] = {
        "file": str(path),
        "capture_id": None,
        "schema_version": None,
        "mode": None,
        "manual_label": None,
        "provenance": None,
        "review_status": None,
        "declared_sample_count": None,
        "observed_sample_count": 0,
        "sources": {source: _new_source_summary() for source in SOURCES},
        "structural_integrity": False,
        "provenance_eligible": False,
        "review_eligible": False,
        "quality_gate_decision": "not_evaluated",
        "errors": [],
        "warnings": [],
    }
    errors: list[str] = result["errors"]
    warnings: list[str] = result["warnings"]

    try:
        handle = path.open("r", encoding="utf-8")
    except OSError as error:
        errors.append(f"file_open_failed:{error}")
        return result

    previous_sequence: int | None = None
    previous_elapsed_by_source: dict[str, float] = {}
    previous_timestamp_by_source: dict[str, float] = {}

    with handle:
        header_line = handle.readline()
        if not header_line:
            errors.append("missing_header")
            return result
        try:
            header = json.loads(header_line)
        except json.JSONDecodeError as error:
            errors.append(f"invalid_header_json:line_1:{error.msg}")
            return result
        if header.get("recordType") != EXPECTED_HEADER_TYPE:
            errors.append("unsupported_header_record_type")
        if header.get("formatVersion") not in SUPPORTED_EXPORT_FORMATS:
            errors.append("unsupported_export_format_version")
        manifest = header.get("manifest")
        if not isinstance(manifest, dict):
            errors.append("missing_manifest")
            return result

        result.update(
            {
                "capture_id": manifest.get("id"),
                "schema_version": manifest.get("schemaVersion"),
                "mode": manifest.get("mode"),
                "manual_label": manifest.get("manualLabel"),
                "provenance": manifest.get("provenance"),
                "review_status": manifest.get("reviewStatus"),
                "declared_sample_count": manifest.get("sampleCount"),
            }
        )
        result["provenance_eligible"] = manifest.get("provenance") == "physical_sensor"
        result["review_eligible"] = manifest.get("reviewStatus") == "valid"
        if not isinstance(manifest.get("id"), str) or not manifest["id"]:
            errors.append("invalid_capture_id")
        if isinstance(manifest.get("schemaVersion"), bool) or not isinstance(
            manifest.get("schemaVersion"), int
        ):
            errors.append("invalid_schema_version")
        if manifest.get("provenance") not in {
            "physical_sensor",
            "simulator_synthetic",
            "automated_test_fixture",
        }:
            errors.append("invalid_provenance")
        if manifest.get("reviewStatus") not in {"pending", "valid", "invalid"}:
            errors.append("invalid_review_status")
        if result["provenance_eligible"] and not isinstance(header.get("participant"), dict):
            warnings.append("physical_capture_missing_participant_metadata")
        external_speed = manifest.get("externalSpeedReference")
        if external_speed is not None:
            if not isinstance(external_speed, dict):
                errors.append("invalid_external_speed_reference")
            else:
                measured_value = external_speed.get("measuredValue")
                if (
                    not _is_finite_number(measured_value)
                    or measured_value <= 0
                ):
                    errors.append("invalid_external_speed_value")
                if not str(external_speed.get("sourceDescription", "")).strip():
                    errors.append("missing_external_speed_source")
                if not str(external_speed.get("pairingIdentifier", "")).strip():
                    errors.append("missing_external_speed_pairing_identifier")
                if not (
                    manifest.get("provenance") == "physical_sensor"
                    and manifest.get("mode") == "single_action"
                    and manifest.get("manualLabel") == "smash"
                ):
                    errors.append("external_speed_not_paired_to_physical_single_smash")

        for line_number, line in enumerate(handle, start=2):
            if not line.strip():
                warnings.append(f"blank_sample_line:line_{line_number}")
                continue
            try:
                sample = json.loads(line)
            except json.JSONDecodeError as error:
                errors.append(f"invalid_sample_json:line_{line_number}:{error.msg}")
                continue
            if not isinstance(sample, dict):
                errors.append(f"sample_is_not_object:line_{line_number}")
                continue
            result["observed_sample_count"] += 1

            sequence = sample.get("sequenceNumber")
            if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
                errors.append(f"invalid_sequence_number:line_{line_number}")
            elif previous_sequence is not None and sequence <= previous_sequence:
                errors.append(f"non_increasing_sequence_number:line_{line_number}")
            if isinstance(sequence, int):
                previous_sequence = sequence

            elapsed = sample.get("elapsedTimeSeconds")
            valid_elapsed: float | None = None
            if not _is_finite_number(elapsed) or elapsed < 0:
                errors.append(f"invalid_elapsed_time:line_{line_number}")
            else:
                valid_elapsed = float(elapsed)

            source = sample.get("source")
            if source not in SOURCES:
                errors.append(f"unsupported_sensor_source:line_{line_number}")
                continue
            source_summary = result["sources"][source]
            source_summary["sample_count"] += 1
            if valid_elapsed is not None:
                previous_elapsed = previous_elapsed_by_source.get(source)
                if previous_elapsed is not None and valid_elapsed < previous_elapsed:
                    errors.append(f"decreasing_elapsed_time:{source}:line_{line_number}")
                previous_elapsed_by_source[source] = valid_elapsed
            if _has_expected_payload(source, sample):
                source_summary["payload_record_count"] += 1
            else:
                errors.append(f"missing_source_payload:{source}:line_{line_number}")

            timestamp = sample.get("monotonicTimestampSeconds")
            if not _is_finite_number(timestamp):
                errors.append(f"invalid_monotonic_timestamp:line_{line_number}")
            else:
                if source_summary["first_timestamp_seconds"] is None:
                    source_summary["first_timestamp_seconds"] = timestamp
                source_summary["last_timestamp_seconds"] = timestamp
                previous_timestamp = previous_timestamp_by_source.get(source)
                if previous_timestamp is not None:
                    delta = timestamp - previous_timestamp
                    if delta < 0:
                        source_summary["non_monotonic_timestamp_count"] += 1
                        errors.append(f"non_monotonic_timestamp:{source}:line_{line_number}")
                    else:
                        _update_interval(source_summary["timestamp_delta"], delta)
                previous_timestamp_by_source[source] = timestamp

            actual_interval = sample.get("actualIntervalSeconds")
            if actual_interval is not None and not _update_interval(
                source_summary["actual_interval"], actual_interval
            ):
                errors.append(f"invalid_actual_interval:{source}:line_{line_number}")

    declared_count = result["declared_sample_count"]
    if (
        isinstance(declared_count, bool)
        or not isinstance(declared_count, int)
        or declared_count < 0
    ):
        errors.append("invalid_declared_sample_count")
    elif declared_count != result["observed_sample_count"]:
        errors.append(
            "sample_count_mismatch:"
            f"declared_{declared_count}:observed_{result['observed_sample_count']}"
        )

    quality = manifest.get("quality") if isinstance(manifest, dict) else None
    if isinstance(quality, dict):
        for field in (
            "abnormalIntervalCount",
            "suspectedDroppedSampleCount",
            "suspectedSaturationSampleCount",
        ):
            value = quality.get(field, 0)
            if isinstance(value, int) and value > 0:
                warnings.append(f"manifest_quality_flag:{field}:{value}")
        source_summaries = quality.get("sourceSummaries")
        if isinstance(source_summaries, list):
            for declared_source in source_summaries:
                if not isinstance(declared_source, dict):
                    errors.append("invalid_manifest_source_summary")
                    continue
                source = declared_source.get("source")
                if source not in SOURCES:
                    errors.append("invalid_manifest_source_summary_source")
                    continue
                declared_source_count = declared_source.get("sampleCount")
                observed_source_count = result["sources"][source]["sample_count"]
                if declared_source_count != observed_source_count:
                    errors.append(
                        "source_sample_count_mismatch:"
                        f"{source}:declared_{declared_source_count}:"
                        f"observed_{observed_source_count}"
                    )

    for source_summary in result["sources"].values():
        _finish_interval(source_summary["actual_interval"])
        _finish_interval(source_summary["timestamp_delta"])

    result["structural_integrity"] = not errors
    return result


def analyze_exports(paths: Iterable[Path]) -> dict[str, Any]:
    captures = [analyze_export(path) for path in paths]
    return {
        "report_format_version": REPORT_FORMAT_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "quality_gate_decision": "not_evaluated",
        "captures": captures,
        "totals": {
            "capture_count": len(captures),
            "observed_sample_count": sum(
                capture["observed_sample_count"] for capture in captures
            ),
            "structurally_valid_capture_count": sum(
                1 for capture in captures if capture["structural_integrity"]
            ),
            "error_count": sum(len(capture["errors"]) for capture in captures),
            "warning_count": sum(len(capture["warnings"]) for capture in captures),
        },
    }


def expand_input_paths(paths: Iterable[Path]) -> list[Path]:
    expanded: list[Path] = []
    for path in paths:
        if path.is_dir():
            expanded.extend(sorted(path.glob("*.badminton-ndjson")))
        else:
            expanded.append(path)
    return expanded


def _markdown_cell(value: Any) -> str:
    if value is None:
        return "—"
    return str(value).replace("|", "\\|").replace("\n", " ")


def _format_seconds(value: Any) -> str:
    return "—" if value is None else f"{value:.6f}"


def render_markdown(report: dict[str, Any]) -> str:
    totals = report["totals"]
    lines = [
        "# 羽毛球研发导出结构分析报告",
        "",
        f"- 生成时间：`{report['generated_at']}`",
        f"- 报告格式版本：`{report['report_format_version']}`",
        "- 质量门禁：`未评估 (not_evaluated)`",
        "- 结论边界：本报告只校验文件结构与客观时序，不代表真机数据质量门禁通过。",
        "",
        "## 汇总",
        "",
        f"- 采集数：{totals['capture_count']}",
        f"- 实际样本数：{totals['observed_sample_count']}",
        f"- 结构通过采集数：{totals['structurally_valid_capture_count']}",
        f"- 错误数：{totals['error_count']}",
        f"- 警告数：{totals['warning_count']}",
        "",
        "| 采集 | 来源 | 复核 | 样本 | 结构 | 错误 | 警告 |",
        "| --- | --- | --- | ---: | --- | ---: | ---: |",
    ]
    for capture in report["captures"]:
        capture_name = capture["capture_id"] or Path(capture["file"]).name
        lines.append(
            "| "
            + " | ".join(
                (
                    _markdown_cell(capture_name),
                    _markdown_cell(capture["provenance"]),
                    _markdown_cell(capture["review_status"]),
                    str(capture["observed_sample_count"]),
                    "通过" if capture["structural_integrity"] else "失败",
                    str(len(capture["errors"])),
                    str(len(capture["warnings"])),
                )
            )
            + " |"
        )

    for capture in report["captures"]:
        capture_name = capture["capture_id"] or Path(capture["file"]).name
        lines.extend(
            [
                "",
                f"## 采集 `{_markdown_cell(capture_name)}`",
                "",
                f"- 文件：`{capture['file']}`",
                f"- 模式 / 人工标签：`{_markdown_cell(capture['mode'])}` / "
                f"`{_markdown_cell(capture['manual_label'])}`",
                f"- 声明 / 实际样本：{_markdown_cell(capture['declared_sample_count'])} / "
                f"{capture['observed_sample_count']}",
                f"- 结构完整：{'yes' if capture['structural_integrity'] else 'no'}",
                "",
                "| 传感器流 | 样本 | 有效负载 | 实际间隔均值(s) | 时间戳差均值(s) | 时间戳逆序 |",
                "| --- | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for source, source_summary in capture["sources"].items():
            lines.append(
                "| "
                + " | ".join(
                    (
                        source,
                        str(source_summary["sample_count"]),
                        str(source_summary["payload_record_count"]),
                        _format_seconds(source_summary["actual_interval"]["mean_seconds"]),
                        _format_seconds(source_summary["timestamp_delta"]["mean_seconds"]),
                        str(source_summary["non_monotonic_timestamp_count"]),
                    )
                )
                + " |"
            )
        for title, values in (("错误", capture["errors"]), ("警告", capture["warnings"])):
            lines.extend(["", f"### {title}", ""])
            if values:
                lines.extend(f"- `{value}`" for value in values)
            else:
                lines.append("- 无")

    lines.extend(
        [
            "",
            "## 门禁声明",
            "",
            "运行结果不包含击球识别、杀球分类、速度估算或阶段 2 真机质量验收结论。",
            "",
        ]
    )
    return "\n".join(lines)


def _parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Stream-check research exports. This does not classify hits, estimate "
            "speed, or decide the physical-device quality gate."
        )
    )
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--compact", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    input_paths = expand_input_paths(arguments.paths)
    if not input_paths:
        print("No .badminton-ndjson files found.", file=sys.stderr)
        return 2
    report = analyze_exports(input_paths)
    if arguments.format == "markdown":
        rendered = render_markdown(report)
    else:
        rendered = json.dumps(
            report,
            ensure_ascii=False,
            indent=None if arguments.compact else 2,
            sort_keys=True,
        )
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 2 if report["totals"]["error_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
