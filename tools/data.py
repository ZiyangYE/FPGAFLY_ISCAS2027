"""Restore release data/firmware or reproduce the MNIST input preprocessing."""
import argparse
from datetime import datetime
import gzip
import io
import os
from pathlib import Path
import re
import shutil
import struct
import tempfile
import urllib.request
import zipfile
from build import check

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://ossci-datasets.s3.amazonaws.com/mnist/"
PEAK_ROWS = (41358, 42869)

def destination(name, folder):
    target = (ROOT / name).resolve()
    allowed = ROOT / folder
    if not target.is_relative_to(allowed) or target == allowed:
        raise RuntimeError('Unexpected archive path: ' + name)
    return target


def open_zip(path):
    """Open a standard ZIP or its consecutive .zip.001, .002, ... volumes."""
    path = Path(path)
    volumes = sorted((p for p in path.parent.glob(path.name + ".*")
                      if p.is_file() and p.suffix[1:].isdigit()),
                     key=lambda p: int(p.suffix[1:]))
    if path.is_file():
        if volumes:
            raise RuntimeError("Both a single ZIP and volumes exist: " + str(path))
        return zipfile.ZipFile(path)
    if not volumes:
        raise FileNotFoundError("Missing ZIP archive or first volume: " + str(path))
    expected = [path.name + f".{index:03d}" for index in range(1, len(volumes) + 1)]
    if [p.name for p in volumes] != expected:
        raise RuntimeError("Missing or misnamed ZIP volume: " + str(path))
    try:
        return zipfile.ZipFile(io.BytesIO(b"".join(p.read_bytes() for p in volumes)))
    except zipfile.BadZipFile as error:
        raise RuntimeError("Incomplete or invalid ZIP volumes: " + str(path)) from error


def restore():
    archive_path = ROOT / 'data/data.zip'
    if not archive_path.is_file() and not archive_path.with_name(archive_path.name + '.001').is_file():
        raise RuntimeError('Missing data/data.zip or data/data.zip.001')
    config = (ROOT / 'ip/ddr3/DDR3_320.ipc').read_text(encoding='utf-8')
    match = re.search(r'^target_device=gw5ast138([bc])-', config, re.M)
    if not match:
        raise RuntimeError('Cannot determine the project device revision')
    revision = match[1].upper()
    with open_zip(ROOT / 'firmware/bitstream.zip') as archive:
        members = archive.infolist()
        if len(members) != 2 or any(m.is_dir() for m in members):
            raise RuntimeError('Expected only a bitstream and synthesis netlist')
        bitstreams = [m for m in members if m.filename.endswith('.fs')]
        if len(bitstreams) != 1:
            raise RuntimeError('Expected one bitstream')
        bitstream = destination(bitstreams[0].filename, 'build')
        build = bitstream.stem
        if bitstream != ROOT / 'build' / build / 'impl/pnr' / (build + '.fs'):
            raise RuntimeError('Unexpected bitstream location')
        expected = {f'build/{build}/impl/pnr/{build}.fs', f'build/{build}/impl/gwsynthesis/{build}.vg'}
        if {m.filename for m in members} != expected:
            raise RuntimeError('Bitstream and netlist do not belong to the same build')
        with archive.open(bitstreams[0]) as stream:
            header = stream.read(2048).decode('ascii').replace('\r\n', '\n')
        if f'//Device Version: {revision}\n' not in header:
            raise RuntimeError('Wrong firmware device revision')
        for entry in members:
            target = destination(entry.filename, 'build')
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            stamp = datetime(*entry.date_time).timestamp()
            os.utime(target, (stamp, stamp))
    # Reports are ordinary files in the release, never firmware archive members.
    for source in (ROOT / 'reports').rglob('*'):
        if not source.is_file():
            continue
        relative = source.relative_to(ROOT / 'reports')
        folder = 'gwsynthesis' if source.name.endswith('_syn.rpt.html') else 'pnr'
        target = destination((Path('build') / build / 'impl' / folder / relative).as_posix(), 'build')
        target.parent.mkdir(parents=True, exist_ok=True)
        content = source.read_text(encoding="utf-8")
        def relocate_link(match):
            relative = match[1]
            href = os.path.relpath(ROOT / relative, target.parent).replace("\\", "/")
            return 'href="' + href + '"'
        content = re.sub(r'href="\.\./((?:rtl|ip|constraints|build)/[^"<>]+)"', relocate_link, content)
        target.write_text(content, encoding="utf-8", newline="")
        shutil.copystat(source, target)
    check(bitstream, max_bsram=270, clock_profile='sync80ref')
    print(f'Rev {revision}: native timing and routing checks passed')
    with open_zip(archive_path) as archive:
        for entry in archive.infolist():
            target = destination((Path('data') / entry.filename).as_posix(), 'data')
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            stamp = datetime(*entry.date_time).timestamp()
            os.utime(target, (stamp, stamp))
    print('Model and reference data restored; bitstream: ' + str(bitstream.relative_to(ROOT)))


def download(name, cache, opener):
    path = cache / name
    if not path.exists():
        print(f"Downloading {name}", flush=True)
        temporary = path.with_suffix(".partial")
        with opener.open(SOURCE + name, timeout=60) as source, temporary.open("wb") as target:
            shutil.copyfileobj(source, target)
        temporary.replace(path)
    return gzip.decompress(path.read_bytes())


def images(data, count):
    if struct.unpack(">4I", data[:16]) != (2051, count, 28, 28):
        raise ValueError("Expected MNIST 28x28 image records")
    if len(data) != 16 + count * 784:
        raise ValueError("Unexpected image payload length")
    return memoryview(data)[16:]


def area_weights():
    # Integer overlap lengths on a common 448-unit axis; each output spans 28 units.
    weights = []
    for out in range(16):
        row = []
        for src in range(28):
            overlap = min((out + 1) * 28, (src + 1) * 16) - max(out * 28, src * 16)
            if overlap > 0:
                row.append((src, overlap))
        weights.append(row)
    return weights


def resize(image, weights):
    horizontal = [
        sum(image[y * 28 + x] * weight for x, weight in column)
        for y in range(28)
        for column in weights
    ]
    # Round only after both axes, so the result is independent of floating point.
    return bytes(
        (sum(horizontal[y * 16 + x] * weight for y, weight in row) + 392) // 784
        for row in weights
        for x in range(16)
    )


def prepare_mnist(args):
    if args.output.exists() and not args.output.is_dir():
        raise ValueError("Output path must be a directory")
    args.cache.mkdir(parents=True, exist_ok=True)
    if args.proxy:
        handler = urllib.request.ProxyHandler({"https": args.proxy, "http": args.proxy})
        opener = urllib.request.build_opener(handler)
    else:
        opener = urllib.request.build_opener()
    test = images(download("t10k-images-idx3-ubyte.gz", args.cache, opener), 10000)
    train = images(download("train-images-idx3-ubyte.gz", args.cache, opener), 60000)
    labels = download("t10k-labels-idx1-ubyte.gz", args.cache, opener)
    if struct.unpack(">2I", labels[:8]) != (2049, 10000) or len(labels) != 10008:
        raise ValueError("Expected 10000 MNIST test labels")
    if max(labels[8:]) > 9:
        raise ValueError("MNIST label outside 0..9")
    args.output.mkdir(parents=True, exist_ok=True)
    weights = area_weights()
    with tempfile.TemporaryDirectory(prefix=".mnist-", dir=args.output) as temporary:
        staged = Path(temporary)
        with (staged / "input.bin").open("wb") as output:
            for row in range(10000):
                output.write(resize(test[row * 784:(row + 1) * 784], weights))
            for row in PEAK_ROWS:
                output.write(resize(train[row * 784:(row + 1) * 784], weights))
        (staged / "test_labels.u8").write_bytes(labels[8:])
        for name in ("input.bin", "test_labels.u8"):
            (staged / name).replace(args.output / name)
    print(f"Wrote 10000 test images, two peak images and test labels to {args.output}")


def accuracy():
    """Check the packaged first-window accuracy reference."""
    data = ROOT / "data"
    labels = (data / "test_labels.u8").read_bytes()
    scores = list(struct.iter_unpack("<10q", (data / "test_scores.i64").read_bytes()))
    if len(labels) != 10000 or len(scores) != len(labels) or max(labels) > 9:
        raise RuntimeError("Incomplete 10,000-image accuracy reference")
    correct = sum(max(range(10), key=lambda digit: row[digit]) == label
                  for row, label in zip(scores, labels))
    print(f"First-window reference accuracy: {correct}/{len(labels)} ({correct / len(labels):.2%})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("restore", help="Restore packaged model and firmware and check the native reports")
    commands.add_parser("accuracy", help="Check the packaged first-window MNIST accuracy reference")
    mnist = commands.add_parser("mnist", help="Download MNIST and reproduce the 16x16 input files")
    mnist.add_argument("--cache", type=Path, default=ROOT / "results/mnist_source")
    mnist.add_argument("--output", type=Path, default=ROOT / "data", help="Destination for input.bin and test_labels.u8; defaults to data/")
    mnist.add_argument("--proxy", help="Optional HTTP proxy for downloads")
    args = parser.parse_args()
    if args.command == "restore":
        restore()
    elif args.command == "accuracy":
        accuracy()
    else:
        prepare_mnist(args)


if __name__ == "__main__":
    main()
