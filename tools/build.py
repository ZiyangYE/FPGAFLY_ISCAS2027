"""Build with Gowin, or check an existing bitstream's native timing/routing reports."""
import argparse
import configparser
from datetime import datetime
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TOOL_BIN = Path("C:/Gowin/Gowin_V1.9.12.03_x64/IDE/bin")

TERMINAL_LOCK = threading.Lock()


class Report:
    def __init__(self, path, title):
        self.path = Path(path)
        self.title = title
        self.lock = threading.Lock()

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open('x', encoding='utf-8')
        self.write(self.title)
        self.write('Started: ' + datetime.now().astimezone().isoformat())
        return self

    def write(self, message):
        message = str(message).rstrip('\r\n')
        for prefix in (str(ROOT), ROOT.as_posix()):
            message = message.replace(prefix, ".")
        with self.lock:
            with TERMINAL_LOCK:
                print(message, flush=True)
            self.stream.write(message + '\n')
            self.stream.flush()

    def run(self, command, cwd=None):
        """Capture a tool's terminal output in this same report."""
        lines = []
        with subprocess.Popen([str(x) for x in command], cwd=cwd,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, encoding='utf-8-sig', errors='replace') as process:
            for line in process.stdout:
                lines.append(line)
                self.write(line)
            code = process.wait()
        if code:
            raise RuntimeError(f'{command[0]} exited with status {code}')
        return ''.join(lines)

    def __exit__(self, kind, error, traceback):
        self.finish('FAIL: ' + str(error) if error is not None else 'PASS')

    def finish(self, status):
        try:
            self.write(status)
            self.write('Finished: ' + datetime.now().astimezone().isoformat())
        finally:
            self.stream.close()



def prepare_reports(directory, names):
    directory = Path(directory)
    for name in names:
        if not name.replace("_", "").isalnum():
            raise ValueError("Invalid report stage name")
        path = directory / (name + ".txt")
        if path.exists():
            raise FileExistsError(f"Report already exists: {path}; choose a new --reports-dir")
    directory.mkdir(parents=True, exist_ok=True)
    return directory


class StageReports:
    """Keep serial workflow stages in separate files; never read reports as state."""
    def __init__(self, directory, names):
        self.directory = Path(directory)
        self.names = tuple(names)
        self.reports = {}
        self.active = None
        self.completed = set()

    def __enter__(self):
        prepare_reports(self.directory, self.names)
        return self

    def select(self, name, title=None):
        if name not in self.names:
            raise ValueError("Unexpected report stage: " + name)
        if name not in self.reports:
            report = Report(self.directory / (name + ".txt"), title or name)
            report.__enter__()
            self.reports[name] = report
        self.active = self.reports[name]
        return self.active

    def complete(self, name):
        self.completed.add(name)

    def __exit__(self, kind, error, traceback):
        for name, report in self.reports.items():
            if report is self.active:
                report.__exit__(kind, error, traceback)
            elif error is None or name in self.completed:
                report.__exit__(None, None, None)
            else:
                report.finish("INCOMPLETE: workflow stopped in another stage")


class Rows(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.row = []
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        if tag in ("td", "th"):
            self.cell = ""
        if tag == "br" and self.cell is not None:
            self.cell += " "

    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.cell is not None:
            self.row.append(self.cell.strip())
            self.cell = None
        if tag == "tr" and self.row:
            self.rows.append(self.row)


def check(bitstream, max_bsram=270, netlist_path=None, clock_profile="sync80ref"):
    if clock_profile != "sync80ref":
        raise ValueError("The final design requires the sync80ref clock profile")
    bitstream = Path(bitstream).resolve()
    report = bitstream.with_name(bitstream.stem + "_tr_content.html")
    netlist = (
        Path(netlist_path).resolve()
        if netlist_path
        else bitstream.parent.parent / "gwsynthesis" / (bitstream.stem + ".vg")
    )
    fs_time = bitstream.stat().st_mtime
    if report.stat().st_mtime < fs_time or netlist.stat().st_mtime > fs_time:
        raise RuntimeError("Stale bitstream or timing report relative to synthesis")
    content = report.read_text(encoding="utf-8", errors="replace")
    clock_section = re.search(r'<a name="Clock_Report".*?</table>', content, re.S)
    constraint_section = re.search(r'<a name="SDC_Report".*?</table>', content, re.S)
    if not clock_section or not constraint_section:
        raise RuntimeError("Missing physical clock or applied-SDC report")
    parser = Rows()
    parser.feed(clock_section.group())
    periods = {row[1]: float(row[3]) for row in parser.rows if len(row) >= 4 and row[0].isdigit()}
    expected_periods = {"board_clk": 20.0, "jtag_clk": 1000.0,
                        "memory_clk": 3.125, "ui_clk": 12.5, "ddr_ref_clk": 15.625}
    if periods.keys() != expected_periods.keys() or any(
        periods[k] != v for k, v in expected_periods.items()
    ):
        raise RuntimeError("Physical clocks differ from board SDC: " + str(periods))
    parser = Rows()
    parser.feed(constraint_section.group())
    applied = [row[2] for row in parser.rows if len(row) == 3 and row[1] == "Actived"]
    required_groups = [
        "set_clock_groups -asynchronous -group [get_clocks {board_clk ddr_ref_clk}] -group [get_clocks {memory_clk}] -group [get_clocks {ui_clk}]",
        "set_clock_groups -asynchronous -group [get_clocks {jtag_clk}] -group [get_clocks {board_clk ddr_ref_clk memory_clk ui_clk}]",
    ]
    if not all(command in applied for command in required_groups):
        raise RuntimeError("Required CDC clock-group constraints are not active")
    section = re.search(r'<a name="Total_Negative_Slack_Report".*?</table>', content, re.S)
    if not section:
        raise RuntimeError("Missing total negative slack report")
    parser = Rows()
    parser.feed(section.group())
    records = []
    for row in parser.rows:
        if len(row) == 4 and row[1] in ("Setup", "Hold"):
            records.append(
                dict(clock=row[0], analysis=row[1], tns=float(row[2]), endpoints=int(row[3]))
            )
    required = {(clock, analysis) for clock in expected_periods for analysis in ("Setup", "Hold")}
    if not required.issubset({(r["clock"], r["analysis"]) for r in records}):
        raise RuntimeError("Missing required clock setup/hold checks")
    failures = [r for r in records if r["tns"] < 0 or r["endpoints"] != 0]
    if failures:
        raise RuntimeError("Timing closure failed: " + json.dumps(failures))
    # Per-clock TNS may omit failures on maximum-delay paths between clocks.
    # Check those paths in the detailed tables too; zero TNS is not enough.
    path_failures = []
    for analysis in ("Setup", "Hold", "Recovery", "Removal"):
        table = re.search(r'<a name="' + analysis + r'_Slack_Table".*?</table>', content, re.S)
        if not table:
            continue
        parser = Rows()
        parser.feed(table.group())
        for row in parser.rows:
            if len(row) >= 4 and row[0].isdigit() and float(row[1]) < 0:
                path_failures.append(
                    dict(analysis=analysis, slack=float(row[1]), source=row[2], destination=row[3])
                )
    if path_failures:
        raise RuntimeError("Detailed timing path violations: " + json.dumps(path_failures))
    route_report = bitstream.with_suffix(".rpt.html")
    route_text = route_report.read_text(encoding="utf-8", errors="replace")
    if route_report.stat().st_mtime < netlist.stat().st_mtime:
        raise RuntimeError("Stale routing report")
    if re.search(r"PR0004|ERROR\s*\(", route_text, re.I):
        raise RuntimeError("Routing report contains an implementation error")
    if "Generate output files:" not in route_text:
        raise RuntimeError("Routing report does not establish completed implementation")
    parser = Rows()
    parser.feed(route_text)
    bsram = None
    for row in parser.rows:
        if row[0] == "BSRAM" and len(row) > 1:
            parts = re.findall(r"(\d+)\s+(?:SDPB|SDPX9B|SPX9B|DPX9B|SP|DP|pROM)\b", row[1])
            if parts:
                bsram = sum(map(int, parts))
        if row and re.search(r"unrout|unroute|not routed", row[0], re.I):
            if len(row) < 2 or not re.fullmatch(r"0", row[1]):
                raise RuntimeError("Unresolved routing: " + str(row))
    if max_bsram is not None and (bsram is None or bsram > max_bsram):
        raise RuntimeError(f"Physical BSRAM budget failed: {bsram}, limit {max_bsram}")
    return dict(
        bitstream=str(bitstream),
        report=str(report),
        routing_report=str(route_report),
        checks=records,
        clock_periods_ns=periods,
        active_clock_groups=required_groups,
        physical_bsram=bsram,
        timing_pass=True,
        routing_pass=True,
    )


def run_gowin(script, tool_bin, license_config=None):
    """Run one build and restore the IDE license configuration even on failure."""
    tool_bin = Path(tool_bin).resolve()
    existing = configparser.ConfigParser()
    existing.read(license_config or tool_bin / "gwlicense.ini")
    target = existing["license"]["lic"].strip('"')
    host, port = target.rsplit(":", 1)
    int(port)
    config = tool_bin / "gwlicense.ini"
    original = config.read_bytes()
    temporary = configparser.ConfigParser()
    temporary["license"] = {"lic": f'"{host}:{port}"'}
    try:
        with config.open("w", encoding="ascii") as stream:
            temporary.write(stream, space_around_delimiters=False)
        print("Running Gowin with the selected license configuration", flush=True)
        subprocess.run([str(tool_bin / "gw_sh.exe"), str(script)], cwd=ROOT, check=True)
    finally:
        config.write_bytes(original)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="thefly")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--replicate-resources", type=int, choices=(0, 1), default=1)
    parser.add_argument("--max-fanout", type=int, default=64)
    parser.add_argument(
        "--license-config",
        type=Path,
        help="Existing Gowin license configuration for a direct connection",
    )
    parser.add_argument(
        "--tool-bin", type=Path, help="Installed Gowin IDE/bin directory; defaults to 1.9.12.03"
    )
    parser.add_argument("--check", type=Path, help="Check an existing .fs and its native reports without building")
    args = parser.parse_args()
    if args.check:
        result = check(args.check)
        print(f"PASS: native timing/routing checks; physical BSRAM: {result['physical_bsram']}")
        return
    jtag = ROOT / "ip/jtag/gw_jtag.v"
    if args.max_fanout < 1:
        parser.error("--max-fanout must be positive")
    if not args.name.replace("_", "").isalnum():
        parser.error("Build name must contain only letters, digits and underscores")
    script = ROOT / "build" / (args.name + ".tcl")
    project = ROOT / "build" / args.name
    if script.exists() or project.exists():
        parser.error("Build directory already exists; choose a new --name")
    sources = [ROOT / line for line in (ROOT / "rtl/files.f").read_text().splitlines() if line]
    sources += [ROOT / "ip/ddr3/DDR3_320.v", jtag]
    constraints = [ROOT / "constraints/tang_mega_pro.cst", ROOT / "constraints/tang_mega_pro.sdc"]
    script.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f'create_project -name {args.name} -dir {{{(ROOT / "build").as_posix()}}} '
        "-pn GW5AST-LV138FPG676AC1/I0 -device_version C",
        *[f"add_file -type verilog {{{path.as_posix()}}}" for path in sources],
        *[f"add_file -type {path.suffix[1:]} {{{path.as_posix()}}}" for path in constraints],
        f'set_option -include_path {{{(ROOT / "rtl").as_posix()}}}',
        "set_option -top_module thefly_top",
        "set_option -use_jtag_as_gpio 0",
        f"set_option -replicate_resources {args.replicate_resources}",
        "set_option -convert_sdp32_36_to_sdp16_18 0",
        "set_option -timing_driven 1",
        "set_option -opt_goal timing",
        "set_option -map_option 1",
        f"set_option -max_fanout {args.max_fanout}",
        "set_option -place_option 3",
        "set_option -route_option 2",
        "set_option -route_maxfan 23",
        "set_option -correct_hold_violation 1",
        "run all",
        "exit",
    ]
    script.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if args.prepare_only:
        print(script)
        return
    run_gowin(script, args.tool_bin or DEFAULT_TOOL_BIN, args.license_config)
    bitstream = project / "impl/pnr" / (args.name + ".fs")
    check(bitstream, max_bsram=270, clock_profile="sync80ref")
    print("Build passed native timing/routing checks: " + str(bitstream))


if __name__ == "__main__":
    main()
