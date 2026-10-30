"""Run the six reference frames and write separate compile, ordinary and peak reports."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
from build import Report, prepare_reports

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "data"
SEQUENTIAL = 1.0928926765918732
DDR_LATENCY = 31


def sources():
    return [ROOT / line for line in (ROOT / "rtl/files.f").read_text().splitlines() if line]


def frame_tests(reports_dir, model=MODEL, output=ROOT / "build/simulation", input_path=MODEL / "input.bin"):
    reports_dir = prepare_reports(reports_dir, ("compile", "ordinary", "peak"))
    output.mkdir(parents=True, exist_ok=True)
    rtl = [p for p in sources() if "/board/" not in p.as_posix() and "/host/" not in p.as_posix()]
    files = rtl + [ROOT / "tests/frame_sim.v", ROOT / "tests/models/primitives.v",
                   ROOT / "tests/frame_replay.cpp", ROOT / "tests/verilator_time.cpp"]
    objects = output / "obj"
    with Report(reports_dir / "compile.txt", "Simulation compilation") as report:
        report.run(["verilator", "--cc", "-I" + str(ROOT / "rtl"), "--exe", "--build",
                    "-j", "8", "-Wno-fatal", "--top-module", "frame_sim", "--Mdir", objects,
                    "--output-split", "20000", "--output-split-cfuncs", "500", "-CFLAGS",
                    "-O3 -std=c++17", "-GPREFETCH=64", "-GLANES=42", *files], cwd=ROOT)

    def replay(mode):
        with Report(reports_dir / (mode + ".txt"), mode + " frame simulation") as report:
            peak = mode == "peak"
            reference = model / "reference"
            count = 2 if peak else 4
            command = [str(objects / "Vframe_sim"), str(ROOT), str(count), str(DDR_LATENCY),
                       str(SEQUENTIAL), str(reference), str(SEQUENTIAL), "4" if peak else "0"]
            env = dict(os.environ, THEFLY_IMAGES=str(model / "model"))
            if input_path is not None:
                env["THEFLY_INPUT"] = str(input_path)
            records = []
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True)
            try:
                for line in process.stdout:
                    if line.startswith("{"):
                        record = json.loads(line)
                        records.append(record)
                        report.write(mode + ": " + "; ".join(f"{key}: {value}" for key, value in record.items()))
                    else:
                        report.write(mode + ": " + line.rstrip())
                code = process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait()
                process.stdout.close()
            passed = code == 0 and len(records) == count and all(
                r["all_states_counts_scores_exact"] and r["cycles"] <= 8_000_000 for r in records)
            if not passed:
                raise RuntimeError(mode + " frame regression failed")
            report.write(f"{mode}: {count} frames passed; worst {max(r['cycles'] for r in records) / 80000:.6f} ms at 80 MHz")
            return records

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(replay, ("ordinary", "peak")))
    print("All six frames match the reference scores, states and counters within 8,000,000 cycles.")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", nargs="?", choices=("all", "frames"), default="frames")
    parser.add_argument("--reports-dir", type=Path, default=ROOT / "results/verification")
    args = parser.parse_args()
    frame_tests(args.reports_dir)


if __name__ == "__main__":
    main()
