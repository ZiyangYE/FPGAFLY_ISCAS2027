"""List adapters, program and accept the design, or test continuous frames."""
import argparse
import ctypes as C
from datetime import datetime
from itertools import islice
import json
import os
from pathlib import Path
import random
import struct
import tempfile
import time
from build import check, StageReports

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "data"
HZ = 80_000_000
REFERENCE_FRAMES = 200
PIXELS = 256
FRAME_OPCODE = 35
CONTINUE_OPCODE = 36
START_T = 2000
STEPS = 1000
EXPECTED_ROWS = (0, 1, 2, 3, 10000, 10001)
MAPPING = [
    (0, "graph_edges.u64"),
    (0x10000000, "source_descriptor.u128"),
    (0x10400000, "readout_coeff.u32"),
    (0x10610000, "readout_bias.i64"),
    (0x10800000, "ordered_descriptor.u64"),
    (0x10980000, "retina_pulses_l42.u32"),
]


MAGIC = 0x44445233
REVERSE_BITS = bytes(int(f"{value:08b}"[::-1], 2) for value in range(256))

def enumerate_adapters():
    driver = C.WinDLL(os.environ.get("THEFLY_D2XX", "ftd2xx.dll"))
    count = C.c_ulong()
    if driver.FT_CreateDeviceInfoList(C.byref(count)):
        raise RuntimeError("Cannot enumerate FTDI")
    devices = []
    for index in range(count.value):
        flags, kind, ident, location = (C.c_ulong() for _ in range(4))
        serial, description = C.create_string_buffer(16), C.create_string_buffer(64)
        handle = C.c_void_p()
        status = driver.FT_GetDeviceInfoDetail(
            index, C.byref(flags), C.byref(kind), C.byref(ident),
            C.byref(location), serial, description, C.byref(handle))
        if status:
            raise RuntimeError(f"FTDI enumeration failed: {status}")
        devices.append(dict(serial=serial.value.decode(), location=location.value,
                            vid_pid=f"{ident.value:08x}",
                            description=description.value.decode(),
                            opened=bool(flags.value & 1)))
    return devices


class Jtag:
    def __init__(self, serial):
        self.d = C.WinDLL(os.environ.get("THEFLY_D2XX", "ftd2xx.dll"))
        self.h = C.c_void_p()
        self.check(self.d.FT_OpenEx(C.c_char_p(serial.encode("ascii")), 1, C.byref(self.h)))
        kind, ident = C.c_ulong(), C.c_ulong()
        device_serial, description = C.create_string_buffer(16), C.create_string_buffer(64)
        self.check(self.d.FT_GetDeviceInfo(
            self.h, C.byref(kind), C.byref(ident), device_serial, description, None
        ))
        if kind.value not in (4, 6, 7, 8):
            self.close()
            raise RuntimeError(f"Unsupported MPSSE device type: {kind.value}")
        self.device_type = kind.value
        self.clock_mhz = 12 if kind.value == 4 else 60
        self.check(self.d.FT_ResetDevice(self.h))
        self.check(self.d.FT_SetTimeouts(self.h, 3000, 3000))
        self.check(self.d.FT_SetUSBParameters(self.h, 65536, 65536))
        self.check(self.d.FT_SetLatencyTimer(self.h, 2))
        self.check(self.d.FT_SetBitMode(self.h, 0, 0))
        self.check(self.d.FT_SetBitMode(self.h, 0, 2))
        time.sleep(0.05)
        self.check(self.d.FT_Purge(self.h, 3))
        if self.clock_mhz == 60:
            self.write(bytes([0x8A, 0x97, 0x8D]))
        self.write(self.clock_command(1) + bytes([0x80, 8, 0x0B, 0x85]))
        self.tms([1] * 6 + [0])
        self.ir(0x11)
        ident = self.scan(0, 32)
        if ident != 0x0001081B:
            self.close()
            raise RuntimeError(f"Wrong JTAG ID: {ident:08x}, expected 0001081b")

    @staticmethod
    def check(status):
        if status:
            raise RuntimeError(f"FTDI status {status}")

    def clock_command(self, mhz):
        if not 0 < mhz <= self.clock_mhz / 2:
            raise ValueError(f"TCK must be positive and at most {self.clock_mhz / 2:g} MHz")
        divisor = round(self.clock_mhz / (2 * mhz)) - 1
        if divisor > 65535:
            raise ValueError("TCK divisor exceeds 16 bits")
        return bytes([0x86, divisor & 255, divisor >> 8])

    def write(self, data):
        data = bytes(data)
        n = C.c_ulong()
        self.check(self.d.FT_Write(self.h, C.c_char_p(data), len(data), C.byref(n)))
        if n.value != len(data):
            raise RuntimeError("Short FTDI write")

    def read(self, n):
        b = C.create_string_buffer(n)
        got = C.c_ulong()
        self.check(self.d.FT_Read(self.h, b, n, C.byref(got)))
        if got.value != n:
            raise TimeoutError(f"FTDI received {got.value}/{n}")
        return b.raw

    def tms(self, bits):
        self.write(bytes([0x4B, len(bits) - 1, sum(v << i for i, v in enumerate(bits))]))

    def scan(self, value, bits, ir=False):
        self.tms([1, 1, 0, 0] if ir else [1, 0, 0])
        full, rem = divmod(bits - 1, 8)
        tx = bytearray()
        if full:
            tx += (
                bytes([0x39, (full - 1) & 255, (full - 1) >> 8])
                + value.to_bytes((bits + 7) // 8, "little")[:full]
            )
        if rem:
            tx += bytes([0x3B, rem - 1, (value >> (full * 8)) & 255])
        tx += bytes([0x6B, 0, 1 | (((value >> (bits - 1)) & 1) << 7), 0x4B, 1, 1, 0x87])
        self.write(tx)
        rx = self.read(full + bool(rem) + 1)
        result = int.from_bytes(rx[:full], "little")
        if rem:
            result |= (rx[full] >> (8 - rem)) << (8 * full)
        result |= ((rx[-1] >> 7) & 1) << (bits - 1)
        return result

    def ir(self, value):
        return self.scan(value, 8, True)

    def exchange(self, words=None):
        return self.exchange_many([words])[0]

    @staticmethod
    def mailbox_commands(packets):
        # Select USER1 and ignore the IR response. End each scan in Idle.
        tx = bytearray([0x4B, 3, 3, 0x1B, 6, 0x42, 0x4B, 0, 1, 0x4B, 1, 1])
        for words in packets:
            payload = bytes(64) if words is None else struct.pack("<16I", *words)
            tx += bytes([0x4B, 2, 1, 0x39, 63, 0]) + payload
            # Add a 513th clock for registered TDI and discard the extra returned bit.
            tx += bytes([0x6B, 0, 1, 0x4B, 1, 1])
        tx += bytes([0x87])
        return bytes(tx)

    def exchange_many(self, packets):
        if not packets:
            return []
        self.write(self.mailbox_commands(packets))
        rx = self.read(65 * len(packets))
        return [list(struct.unpack("<16I", rx[i * 65 : i * 65 + 64])) for i in range(len(packets))]

    def command(self, op, base=0, data=None, mask=0):
        if op not in (3, 4) or base < 0 or base % 32 or base + 32 > 1 << 30:
            raise ValueError("Require read/write opcode and aligned 32-byte range inside 1 GiB")
        seq = (((time.perf_counter_ns() >> 10) & 0xFFFFFF) << 8) | op
        words = [MAGIC, seq, base, 1, 0, 0, 0, mask] + (data or [0] * 8)
        status = self.exchange()
        if status[0] != MAGIC:
            raise RuntimeError(f"JTAG mailbox unavailable: {status}")
        if status[2] & 1:
            raise RuntimeError("DDR bench busy")
        self.exchange(words)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            time.sleep(0.01)
            r = self.exchange()
            if r[0] == MAGIC and r[1] == seq and not (r[2] & 1):
                out = {
                    "op": op,
                    "base": base,
                    "flags": r[2],
                    "errors": r[3],
                    "first_error": r[4],
                    "read_completed": r[5],
                    "write_accepted": r[6],
                    "raw": r,
                    "data": r[8:16],
                }
                if r[2] & 24:
                    raise RuntimeError(json.dumps(out))
                return out
        raise TimeoutError("DDR response timeout")

    def close(self):
        if self.h:
            self.d.FT_SetBitMode(self.h, 0, 0)
            self.d.FT_Close(self.h)
            self.h = None


class BulkJtag(Jtag):
    def begin(self, op, base, blocks):
        if base % 32 or blocks < 1 or base + blocks * 32 > 1 << 30:
            raise ValueError("Aligned nonempty range must fit DDR")
        status = self.exchange()
        if status[0] != MAGIC or status[2] & 1 or not status[2] & 4:
            raise RuntimeError(f"DDR unavailable: {status}")
        seq = (((time.perf_counter_ns() >> 10) & 0xFFFFFF) << 8) | op
        self.exchange([MAGIC, seq, base, blocks] + [0] * 12)
        return seq

    def finish(self, seq, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            r = self.exchange()
            if r[0] == MAGIC and r[1] == seq and not r[2] & 1:
                if r[2] & 24:
                    raise RuntimeError(f"DDR operation failed: {r}")
                return r
            time.sleep(0.002)
        raise TimeoutError(f"Command {seq:08x}")

    def scores(self):
        data = []
        packets = []
        sequences = []
        initial = (time.perf_counter_ns() >> 10) & 0xFFFFFF
        for page in range(3):
            seq = (((initial + page) & 0xFFFFFF) << 8) | 33
            sequences.append(seq)
            packets.append([MAGIC, seq, page] + [0] * 13)
        # Capture-DR returns the previous page; batch the scans into one USB transfer.
        replies = self.exchange_many(packets + [None])[1:]
        for seq, reply in zip(sequences, replies):
            if reply[0] != MAGIC or reply[1] != seq or reply[2] & 25:
                raise RuntimeError(f"Invalid score page response: {reply}")
            data.extend(struct.unpack("<4q", struct.pack("<8I", *reply[8:16])))
        return data[:10]

    def read_states(self, ids):
        ids = list(ids)
        if any(i < 0 or i >= 166700 for i in ids):
            raise ValueError("Neuron ID outside the full network")
        states = []
        for start in range(0, len(ids), 128):
            batch = ids[start : start + 128]
            initial = (time.perf_counter_ns() >> 10) & 0xFFFFFF
            sequences = [
                (((initial + i) & 0xFFFFFF) << 8) | 34 for i in range(len(batch))
            ]
            packets = [
                [MAGIC, seq, neuron] + [0] * 13 for seq, neuron in zip(sequences, batch)
            ]
            replies = self.exchange_many(packets + [None])[1:]
            for seq, reply in zip(sequences, replies):
                if reply[0] != MAGIC or reply[1] != seq or reply[2] & 25:
                    raise RuntimeError(f"Invalid state response: {reply}")
                states.append((reply[8] | reply[9] << 32) & ((1 << 41) - 1))
        return states

    def upload(self, path, base=0, mhz=None, progress=None):
        path = Path(path)
        size = path.stat().st_size
        padded = (size + 31) & ~31
        if mhz is None:
            mhz = 3 if self.clock_mhz == 12 else 10
        if mhz not in (1, 1.25, 2, 2.5, 3, 5, 6, 10):
            raise ValueError("Unsupported nominal TCK")
        clock_command = self.clock_command(mhz)
        seq = self.begin(16, base, padded // 32)
        self.ir(0x43)
        self.write(clock_command)
        self.tms([1, 0, 0])
        start = time.perf_counter()
        sent = 0
        with path.open("rb") as stream:
            while True:
                chunk = stream.read(16384)
                if not chunk:
                    break
                if len(chunk) % 32:
                    chunk += bytes(32 - len(chunk) % 32)
                chunk = chunk.translate(REVERSE_BITS)
                self.write(
                    bytes([0x11, (len(chunk) - 1) & 255, (len(chunk) - 1) >> 8]) + chunk
                )
                sent += len(chunk)
                if progress and (sent % (4 << 20) == 0 or sent == padded):
                    progress(sent, padded)
        # Add one final shift clock for the registered TDI input.
        self.write(bytes([0x4B, 0, 1, 0x4B, 1, 1]) + self.clock_command(1) + bytes([0x87]))
        r = self.finish(seq)
        upload_seconds = time.perf_counter() - start
        if r[6] != padded // 32:
            raise RuntimeError(f"Upload accepted {r[6]} of {padded//32} blocks")
        return dict(
            file=str(path.resolve()),
            base=base,
            bytes=size,
            padded_bytes=padded,
            nominal_tck_mhz=mhz,
            configured_tck_mhz=self.clock_mhz / (2 * (int.from_bytes(clock_command[1:], "little") + 1)),
            ftdi_device_type=self.device_type,
            msb_first_with_reversed_bytes=True,
            actual_tck_measured=False,
            upload_seconds=upload_seconds,
            upload_MBps=padded / upload_seconds / 1e6,
            accepted_blocks=r[6],
        )


def programmer_device(bitstream):
    with bitstream.open(encoding="ascii") as stream:
        header = {line.strip() for line in islice(stream, 32)}
    if "//Device: GW5AST-138" not in header:
        raise RuntimeError("Expected a GW5AST-138 bitstream")
    revisions = [revision for revision in ("B", "C")
                 if f"//Device Version: {revision}" in header]
    if len(revisions) != 1:
        raise RuntimeError("Expected an unambiguous B or C bitstream revision")
    return "GW5AST-138" + revisions[0]


def reference_rows(model):
    rows = [value[0] for value in struct.iter_unpack("<I", (model / "reference/rows.bin").read_bytes())]
    if tuple(rows) != EXPECTED_ROWS:
        raise RuntimeError("Unexpected six-image reference selection")
    return rows


def run_acceptance(args, reports):
    report = reports.select("precheck", "Device and implementation checks")
    if args.cable_index < 0:
        raise ValueError("--cable-index must be nonnegative")
    if not 1 <= args.state_samples <= 166700:
        raise ValueError("--state-samples must be between 1 and 166700")
    model = args.model.resolve()
    temporary = tempfile.TemporaryDirectory(prefix="thefly-accept-")
    output = Path(temporary.name)
    result = dict(
        started=datetime.now().astimezone().isoformat(),
        passed=False,
        operation="SRAM only",
        timing_scope="FPGA frame cycles / 80 MHz; excludes host transfers and readback",
        fpga_clock_hz=HZ,
        runs=[],
        uploads=[],
    )
    j = None

    def save(stage):
        result["stage"] = stage
        report.write(datetime.now().isoformat() + " " + stage)

    def run(command, name):
        report.write(name)
        return report.run(command, cwd=ROOT)

    try:
        bitstream = args.bitstream.resolve()
        check(bitstream, max_bsram=270, clock_profile="sync80ref")
        result["programmer_device"] = programmer_device(bitstream)
        report.write("Native timing/routing checks passed; target: " + result["programmer_device"])
        report.write("Bitstream: " + str(bitstream))
        report.write("Model: " + str(model))
        reference = model / "reference"
        rows = reference_rows(model)
        scores = list(struct.iter_unpack("<10q", (reference / "scores.i64").read_bytes()))
        stats = list(struct.iter_unpack("<10Q", (reference / "stats.u64").read_bytes()))
        if len(rows) != len(scores) or len(rows) != len(stats):
            raise RuntimeError("Reference length mismatch")
        cases = []
        with (model / "input.bin").open("rb") as stream:
            for index, row in enumerate(rows):
                stream.seek(row * PIXELS)
                data = stream.read(PIXELS)
                if len(data) != PIXELS:
                    raise RuntimeError("Input truncated")
                path = output / f"input_{row}.bin"
                path.write_bytes(data)
                cases.append(dict(row=row, index=index, path=path,
                                  scores=list(scores[index]), stats=stats[index]))
        devices = [d for d in enumerate_adapters() if d["serial"] == args.serial]
        if len(devices) != 1:
            raise RuntimeError("Expected one adapter with the requested serial")
        info = devices[0]
        report.write(f"Adapter: {args.serial}; USB location: {info['location']}")
        if (
            info["serial"] != args.serial
            or info["vid_pid"] != "04036010"
            or info["opened"]
        ):
            raise RuntimeError("FTDI identity or ownership mismatch")
        result["adapter"] = info
        common = [str(args.programmer.resolve()), "--cable-index", str(args.cable_index),
                  "--location", str(info["location"])]
        scan = run(common + ["--frequency", "10MHz", "--scan"], "JTAG scan")
        if "ID: 0x0001081B" not in scan:
            raise RuntimeError("Wrong physical FPGA ID")
        save("identity and production build verified")
        reports.complete("precheck")
        report = reports.select("programming", "SRAM programming and DDR calibration")
        programming = run(
            common
            + [
                "--frequency",
                "10MHz",
                "--device",
                result["programmer_device"],
                "--operation_index",
                "2",
                "--fsFile",
                str(bitstream),
            ],
            "SRAM programming",
        )
        if (
            'Operation "SRAM Program"' not in programming
            or "Finished." not in programming
            or "100%" not in programming
            or "error" in programming.lower()
            or "failed" in programming.lower()
        ):
            raise RuntimeError("Programmer did not confirm completed SRAM programming")
        result["programmed"] = datetime.now().astimezone().isoformat()
        j = BulkJtag(args.serial)
        deadline = time.monotonic() + 30
        while True:
            status = j.exchange()
            if status[0] == MAGIC and status[2] & 4 and not status[2] & 25:
                break
            if time.monotonic() > deadline:
                raise RuntimeError(f"Calibration/mailbox unavailable: {status}")
            time.sleep(0.1)
        result["calibration_mailbox"] = status
        save("SRAM loaded; DDR calibrated")
        reports.complete("programming")
        report = reports.select("upload", "Model and input upload")
        rng = random.Random(0x80320)
        save("DDR calibrated; uploading model")
        for base, name in MAPPING:

            def progress(sent, total):
                report.write(f"Uploading {name}: {sent}/{total} bytes")

            result["uploads"].append(
                j.upload(model / "model" / name, base, mhz=args.mhz, progress=progress)
            )
            save(f"uploaded {name}")
        # Sample each uploaded image, including its last padded block.
        for base, name in MAPPING:
            path = model / "model" / name
            size = path.stat().st_size
            offsets = sorted(
                {
                    0,
                    ((size - 1) // 32) * 32,
                    *[rng.randrange((size + 31) // 32) * 32 for _ in range(32)],
                }
            )
            with path.open("rb") as stream:
                for offset in offsets:
                    stream.seek(offset)
                    want = stream.read(32).ljust(32, b"\0")
                    got = struct.pack("<8I", *j.command(3, base=base + offset)["data"])
                    if got != want:
                        raise RuntimeError(
                            f"Model sample readback mismatch {name}+{offset}"
                        )
        result["model_sample_readback_pass"] = True
        result["uploads"].append(
            j.upload(reference / "warm.u64", 0x18000000, mhz=args.mhz)
        )
        result["uploads"].append(
            j.upload(reference / "warm_queue.bin", 0x1A000000, mhz=args.mhz)
        )
        save(
            "model uploaded and sampled readback passed; running six frames"
        )
        for case in cases:
            start = time.perf_counter()
            report = reports.select("upload")
            j.upload(case["path"], 0x10700000, mhz=args.mhz,
                     progress=lambda sent, total: report.write(f"Input {case['row']}: {sent}/{total} bytes"))
            if case is cases[-1]:
                reports.complete("upload")
            report = reports.select("acceptance", "Six-image functional acceptance")
            seq = j.begin(FRAME_OPCODE, 0, 1)
            reply = j.finish(seq, timeout=5)
            if reply[4] != START_T + STEPS - 1:
                raise RuntimeError("Wrong final timestep")
            scores = j.scores()
            elapsed = time.perf_counter() - start
            cycles = reply[9] | reply[10] << 32
            record = dict(
                row=case["row"],
                raw=reply,
                host_end_to_end_seconds=elapsed,
                fpga_cycles=cycles,
                fpga_clock_hz=HZ,
                advertised_clock_hz=reply[15],
                fpga_seconds=cycles / HZ,
                scores=scores,
                scores_exact=scores == case["scores"],
                counters_exact=reply[5] == case["stats"][1]
                and reply[6] == case["stats"][5],
                winner_exact=reply[8]
                == max(range(10), key=lambda i: case["scores"][i]),
                ten_hz_met=cycles <= HZ // 10,
            )
            result["runs"].append(record)
            save(f'frame {case["row"]}: compute {cycles / HZ:.9f}s')
            report.write(f"Scores: {scores}; spikes: {reply[5]}; edges: {reply[6]}; winner: {reply[8]}")
            if not all(
                record[k]
                for k in ("scores_exact", "counters_exact", "winner_exact")
            ):
                raise RuntimeError("Frame reference mismatch")
            # Sample tile boundaries and random cells.
            with (reference / "states.u64").open("rb") as states:
                states.seek(case["index"] * 166700 * 8)
                expected_states = struct.unpack("<166700Q", states.read(166700 * 8))
            sample_rng = random.Random(0x80320 + case["row"])
            boundary_ids = list(range(42)) + list(range(166658, 166700))
            boundary_ids += [3554, 3555, 5326, 5327, 8661, 8662]
            selected = set(boundary_ids[: args.state_samples])
            while len(selected) < args.state_samples:
                selected.add(sample_rng.randrange(166700))
            ids = sorted(selected)
            for first in range(0, len(ids), 128):
                batch = ids[first : first + 128]
                states = j.read_states(batch)
                for neuron, value in zip(batch, states):
                    if value != expected_states[neuron] & ((1 << 41) - 1):
                        raise RuntimeError(
                            f'State mismatch row {case["row"]} neuron {neuron}'
                        )
            record["state_samples_exact"] = True
            record["state_sample_ids"] = ids
            save(f'frame {case["row"]}: {len(ids)} sampled states exact')
        result["functional_pass"] = True
        result["worst_fpga_seconds"] = max(r["fpga_seconds"] for r in result["runs"])
        result["worst_host_seconds"] = max(
            r["host_end_to_end_seconds"] for r in result["runs"]
        )
        result["ten_hz_met"] = all(r["ten_hz_met"] for r in result["runs"])
        result["passed"] = result["ten_hz_met"]
        if not result["passed"]:
            raise RuntimeError("Frame exceeded the 10 Hz deadline")
        report.write(f"Six images passed; worst FPGA compute: {result['worst_fpga_seconds']:.9f} s; worst host transaction: {result['worst_host_seconds']:.9f} s")
        save("complete")
    except Exception as exc:
        result["failure"] = repr(exc)
        save("failed")
        raise
    finally:
        try:
            if j is not None:
                j.close()
        finally:
            temporary.cleanup()


def run_continuous(args, reports):
    report = reports.select("precheck", "Live device and model checks")
    model = args.model.resolve()
    bitstream = args.bitstream.resolve()
    check(bitstream, max_bsram=270, clock_profile='sync80ref')
    report.write('Native timing/routing checks passed; target: ' + programmer_device(bitstream))
    report.write("Bitstream: " + str(bitstream))
    report.write("Model: " + str(model))
    devices = [d for d in enumerate_adapters() if d['serial'] == args.serial]
    if len(devices) != 1 or devices[0]['opened'] or devices[0]['vid_pid'] != '04036010':
        raise RuntimeError('Target adapter identity or ownership mismatch')
    report.write(f"Adapter: {args.serial}; USB location: {devices[0]['location']}")
    reference = model / 'reference'
    rows = reference_rows(model)
    scores = list(struct.iter_unpack('<10q', (reference / 'continuous_scores.i64').read_bytes()))
    activity = list(struct.iter_unpack('<3Q', (reference / 'continuous_activity.u64').read_bytes()))
    if len(rows) != 6 or len(scores) != len(rows) * REFERENCE_FRAMES or len(activity) != len(scores):
        raise RuntimeError('Incomplete continuous-frame reference')
    total_cycles = 0
    worst_cycles = 0
    jtag = None
    with tempfile.TemporaryDirectory(prefix='thefly-repeat-') as temporary:
        try:
            jtag = BulkJtag(args.serial)
            status = jtag.exchange()
            if status[0] != MAGIC or not status[2] & 4 or status[2] & 25:
                raise RuntimeError('FPGA mailbox or calibrated DDR unavailable')
            # Independently check the loaded model and initial state; no previous report is read.
            inputs = [(base, model / 'model' / name) for base, name in MAPPING]
            inputs += [(0x18000000, model / 'reference/warm.u64'),
                       (0x1A000000, model / 'reference/warm_queue.bin')]
            for base, path in inputs:
                size = path.stat().st_size
                rng = random.Random(0x80320 + base)
                offsets = sorted({0, ((size - 1) // 32) * 32,
                                  *[rng.randrange((size + 31) // 32) * 32 for _ in range(32)]})
                with path.open('rb') as stream:
                    for offset in offsets:
                        stream.seek(offset)
                        expected = stream.read(32).ljust(32, b'\0')
                        actual = struct.pack('<8I', *jtag.command(3, base=base + offset)['data'])
                        if actual != expected:
                            raise RuntimeError(f'Loaded data differs at {path.name}+{offset}; run SRAM programming and model upload first')
                report.write(f'Loaded data checked: {path.name}; {len(offsets)} sampled blocks')
            reports.complete('precheck')
            with (model / 'input.bin').open('rb') as images:
                for case, row in enumerate(rows):
                    images.seek(row * 256)
                    image = images.read(256)
                    if len(image) != 256:
                        raise RuntimeError('Truncated input image')
                    image_path = Path(temporary) / 'input.bin'
                    image_path.write_bytes(image)
                    report = reports.select("upload", "Continuous-test input upload")
                    jtag.upload(image_path, 0x10700000, mhz=args.mhz,
                                progress=lambda sent, total: report.write(f'Input upload: {sent}/{total} bytes'))
                    if case == len(rows) - 1:
                        reports.complete("upload")
                    report = reports.select("continuous", "Continuous frame test")
                    cycles = []
                    for frame in range(args.frames):
                        opcode = FRAME_OPCODE if frame == 0 else CONTINUE_OPCODE
                        reply = jtag.finish(jtag.begin(opcode, 0, 1), timeout=5)
                        actual = jtag.scores()
                        count = reply[9] | reply[10] << 32
                        index = case * REFERENCE_FRAMES + frame
                        expected = scores[index]
                        checks = dict(scores=actual == list(expected),
                                      spikes=reply[5] == activity[index][1],
                                      edges=reply[6] == activity[index][2],
                                      winner=reply[8] == max(range(10), key=lambda digit: expected[digit]),
                                      timestep=reply[4] == START_T + STEPS - 1,
                                      realtime=count <= HZ // 10)
                        if not all(checks.values()):
                            failed = ', '.join(key for key, ok in checks.items() if not ok)
                            raise RuntimeError(f'Row {row}, frame {frame + 1}: failed {failed}')
                        cycles.append(count)
                        total_cycles += count
                    if args.frames == REFERENCE_FRAMES:
                        ids = sorted(random.Random(0x80320 + row).sample(range(166700), 256))
                        actual_states = jtag.read_states(ids)
                        with (reference / 'continuous_states.u64').open('rb') as states:
                            states.seek(case * 166700 * 8)
                            expected_states = struct.unpack('<166700Q', states.read(166700 * 8))
                        if actual_states != [expected_states[neuron] for neuron in ids]:
                            raise RuntimeError(f'Final state sample mismatch for row {row}')
                        report.write(f'Row {row}: 256 final sampled states exact')
                    worst_cycles = max(worst_cycles, max(cycles))
                    report.write(f'Row {row}: {args.frames} windows passed; min {min(cycles) / 80000:.6f} ms; max {max(cycles) / 80000:.6f} ms')
            report.write(f'Completed {len(rows) * args.frames} windows; total FPGA compute {total_cycles / HZ:.9f} s; worst {worst_cycles / 80000:.6f} ms')
            report.write('FPGA computation time excludes host communication.')
        finally:
            if jtag is not None:
                jtag.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    adapters = commands.add_parser("adapters", help="List FTDI adapters without opening a board")
    adapters.add_argument("--serial")
    accept = commands.add_parser("accept", help="Check reports, program SRAM, upload the model and test six images")
    repeat = commands.add_parser("repeat", help="Independently check and test the already loaded design")
    for command, directory in ((accept, "board_acceptance"), (repeat, "repeated_frames")):
        command.add_argument("--bitstream", type=Path, required=True)
        command.add_argument("--serial", required=True)
        command.add_argument("--model", type=Path, default=MODEL)
        command.add_argument("--mhz", type=float)
        command.add_argument("--reports-dir", type=Path, default=ROOT / "results" / directory)
    accept.add_argument("--state-samples", type=int, default=256)
    accept.add_argument("--programmer", type=Path, required=True)
    accept.add_argument("--cable-index", type=int, required=True)
    repeat.add_argument("--frames", type=int, default=REFERENCE_FRAMES)
    args = parser.parse_args()
    if args.command == "adapters":
        devices = enumerate_adapters()
        if args.serial:
            devices = [d for d in devices if d["serial"] == args.serial]
            if len(devices) != 1:
                raise RuntimeError(f"Expected one interface with serial {args.serial}, found {len(devices)}")
        for device in devices:
            print("; ".join(f"{key}: {value}" for key, value in device.items()))
        return
    if args.command == "repeat" and not 2 <= args.frames <= REFERENCE_FRAMES:
        parser.error("The reference covers 2 to 200 frames per image")
    stages = ("precheck", "programming", "upload", "acceptance") if args.command == "accept" else ("precheck", "upload", "continuous")
    with StageReports(args.reports_dir, stages) as reports:
        if args.command == "accept":
            run_acceptance(args, reports)
        else:
            run_continuous(args, reports)


if __name__ == "__main__":
    main()
