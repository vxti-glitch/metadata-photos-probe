#!/usr/bin/env python3
"""Export public xcresulttool diagnostics without changing the test process result."""
import argparse
import json
from pathlib import Path
import subprocess


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def command_json(arguments, output, errors):
    result = subprocess.run(["xcrun", "xcresulttool", *arguments], capture_output=True, text=True)
    errors.write("Command: xcresulttool " + " ".join(arguments) + "\n")
    errors.write(result.stderr + f"\nExit: {result.returncode}\n")
    if result.returncode:
        print(f"Diagnostic query failed ({result.returncode}): {output.name}")
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        errors.write("Command did not return JSON.\n")
        return None
    output.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    return value


def print_failures(value):
    emitted = set()
    for node in walk(value):
        identifier = next((node.get(key) for key in ["testIdentifierString", "testIdentifier", "testName", "name"]
                           if isinstance(node.get(key), str)), "Native test")
        for key in ["failureText", "message", "failureMessage"]:
            text = node.get(key)
            if not isinstance(text, str) or not text or text in emitted:
                continue
            emitted.add(text)
            print(f"{identifier}: {text[:1600]}")
            if len(emitted) >= 30:
                return


def failed_identifiers(value):
    identifiers = set()
    for node in walk(value):
        result = str(node.get("result", node.get("testResult", ""))).lower()
        failed = result in ("failed", "failure") or any(key in node for key in ["failureText", "failureMessage"])
        if not failed:
            continue
        identifier = next((node.get(key) for key in ["testIdentifierURL", "testIdentifier", "nodeIdentifier", "testIdentifierString"]
                           if isinstance(node.get(key), str) and node.get(key)), None)
        if identifier:
            identifiers.add(identifier)
    return sorted(identifiers)[:30]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", required=True)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    result = Path(args.result).resolve()
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    if not result.is_dir():
        print("Native test result bundle was not created; preserve xcodebuild log and exit status.")
        return
    with (evidence / "xcresulttool-diagnostics.log").open("w", encoding="utf-8") as errors:
        summary = command_json(["get", "test-results", "summary", "--path", str(result)],
                               evidence / "native-test-summary.json", errors)
        tests = command_json(["get", "test-results", "tests", "--path", str(result)],
                             evidence / "native-test-tree.json", errors)
        command_json(["get", "build-results", "--path", str(result)],
                     evidence / "native-build-results.json", errors)
        command_json(["get", "content-availability", "--path", str(result)],
                     evidence / "native-result-content.json", errors)
        if summary:
            print("Native XCTest summary:")
            for key in ["result", "totalTestCount", "passedTests", "failedTests", "skippedTests"]:
                if key in summary:
                    print(f"  {key}: {summary[key]}")
            print_failures(summary)
        if not summary:
            # Apple's documented legacy object API is a diagnostics fallback only.
            legacy = command_json(["get", "object", "--legacy", "--path", str(result), "--format", "json"],
                                  evidence / "native-result-legacy.json", errors)
            if legacy:
                print_failures(legacy)
        for index, identifier in enumerate(failed_identifiers(tests or summary or {}), 1):
            details = command_json(["get", "test-results", "test-details", "--path", str(result),
                                    "--test-id", identifier], evidence / f"native-failed-test-{index:02d}.json", errors)
            if details:
                print_failures(details)
        diagnostics = subprocess.run(["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(result),
                                      "--output-path", str(evidence / "native-diagnostics")],
                                     capture_output=True, text=True)
        errors.write("Export diagnostics:\n" + diagnostics.stdout + diagnostics.stderr
                     + f"\nExit: {diagnostics.returncode}\n")
        print(f"Native result diagnostic export exit: {diagnostics.returncode}")


if __name__ == "__main__":
    main()
