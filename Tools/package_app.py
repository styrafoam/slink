#!/usr/bin/env python3
"""Package slink using the byte budgets in size-targets.json.

See PACKAGING.md for the inert padding design and archive checks.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import zipfile


FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
BALLAST_NAME = "SizeBallast.bin"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(*args: str) -> None:
    completed = subprocess.run(args, capture_output=True, text=True)
    if completed.returncode:
        raise RuntimeError(f"{args[0]} failed: {completed.stderr.strip()}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_files(app: Path) -> list[Path]:
    paths = sorted(p for p in app.rglob("*") if p.is_file())
    require(not any(p.is_symlink() for p in app.rglob("*")),
            "This size matcher deliberately supports bundles without symlinks only.")
    return paths


def logical_bytes(app: Path) -> int:
    return sum(path.stat().st_size for path in bundle_files(app))


def executable(app: Path) -> Path:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    name = info["CFBundleExecutable"]
    require(isinstance(name, str) and Path(name).name == name,
            "CFBundleExecutable must be a simple filename.")
    return app / "Contents/MacOS" / name


def file_manifest(app: Path) -> dict:
    return {str(p.relative_to(app)): {"bytes": p.stat().st_size, "sha256": sha256(p)}
            for p in bundle_files(app)}


def pad_adhoc_universal(data: bytes, desired_bytes: int) -> tuple[bytearray, int]:
    """Expand final slice's existing signature allocation; preserve loaded code.

    Ad-hoc signatures do not contain a CMS signer. Header size fields change, so
    their CodeDirectory code-page hashes are regenerated. All special hashes,
    requirements, entitlements, identifiers and actual program data stay intact.
    Padding follows the parsed signature SuperBlob and is never loaded as code.
    """
    binary = bytearray(data)
    require(len(binary) >= 8 and struct.unpack_from(">I", binary)[0] == FAT_MAGIC,
            "Expected a big-endian FAT32 universal Mach-O from lipo.")
    count = struct.unpack_from(">I", binary, 4)[0]
    require(1 <= count <= 8, "Invalid universal architecture count.")
    arches = [struct.unpack_from(">IIIII", binary, 8 + i * 20) for i in range(count)]
    last_index = max(range(count), key=lambda i: arches[i][2])
    _, _, base, old_size, alignment = arches[last_index]
    require(base + old_size == len(binary), "Unexpected bytes after final FAT slice.")
    require(base % (1 << alignment) == 0, "Invalid FAT slice alignment.")
    require(desired_bytes >= len(binary), "Compiled executable exceeds the byte budget.")
    added = desired_bytes - len(binary)
    require(added > 0, "Executable needs spare signature space for ZIP size matching.")
    thin = bytearray(binary[base:])
    require(struct.unpack_from("<I", thin)[0] == MH_MAGIC_64,
            "Expected a little-endian 64-bit final slice.")
    commands = struct.unpack_from("<I", thin, 16)[0]
    cursor = 32
    signature_command = linkedit_command = None
    for _ in range(commands):
        cmd, size = struct.unpack_from("<II", thin, cursor)
        require(size >= 8 and cursor + size <= len(thin), "Invalid Mach-O command.")
        if cmd == LC_CODE_SIGNATURE:
            signature_command = cursor
        if (cmd == LC_SEGMENT_64 and
                thin[cursor + 8:cursor + 24].split(b"\0")[0] == b"__LINKEDIT"):
            linkedit_command = cursor
        cursor += size
    require(signature_command is not None and linkedit_command is not None,
            "Final slice needs an embedded ad-hoc signature and __LINKEDIT.")
    sig_offset, sig_size = struct.unpack_from("<II", thin, signature_command + 8)
    require(sig_offset + sig_size == old_size, "Signature allocation must end the slice.")
    magic, superblob_size, blobs = struct.unpack_from(">III", thin, sig_offset)
    require(magic == CSMAGIC_EMBEDDED_SIGNATURE and superblob_size <= sig_size,
            "Invalid embedded signature SuperBlob.")
    directories = []
    for index in range(blobs):
        slot, offset = struct.unpack_from(">II", thin, sig_offset + 12 + index * 8)
        blob_offset = sig_offset + offset
        blob_magic = struct.unpack_from(">I", thin, blob_offset)[0]
        # CSSLOT_SIGNATURESLOT (0x10000) is empty in an ad-hoc signature.
        if slot == 0x10000:
            require(struct.unpack_from(">I", thin, blob_offset + 4)[0] == 8,
                    "Refusing to modify a non-ad-hoc CMS signature.")
        if blob_magic == CSMAGIC_CODEDIRECTORY:
            flags = struct.unpack_from(">I", thin, blob_offset + 12)[0]
            require(flags & 2, "CodeDirectory must explicitly be ad-hoc signed.")
            directories.append(blob_offset)
    require(directories, "No supported ad-hoc CodeDirectory.")
    require(old_size + added < 2**32, "FAT32 size overflow.")
    struct.pack_into("<I", thin, signature_command + 12, sig_size + added)
    file_offset, file_size = struct.unpack_from("<QQ", thin, linkedit_command + 40)
    require(file_offset + file_size == old_size, "__LINKEDIT must end with signature.")
    struct.pack_into("<Q", thin, linkedit_command + 48, file_size + added)
    page = 16384 if arches[last_index][0] == 0x0100000C else 4096
    struct.pack_into("<Q", thin, linkedit_command + 32,
                     math.ceil((file_size + added) / page) * page)
    thin.extend(bytes(added))
    for cd in directories:
        hash_offset = struct.unpack_from(">I", thin, cd + 16)[0]
        slots = struct.unpack_from(">I", thin, cd + 28)[0]
        code_limit = struct.unpack_from(">I", thin, cd + 32)[0]
        hash_size, hash_type, _, page_power = struct.unpack_from("BBBB", thin, cd + 36)
        require(code_limit == sig_offset and page_power > 0,
                "Unsupported CodeDirectory code limit or page size.")
        require(hash_type in (1, 2, 3, 4), "Unsupported CodeDirectory hash algorithm.")
        digest = {1: hashlib.sha1, 2: hashlib.sha256,
                  3: hashlib.sha256, 4: hashlib.sha384}[hash_type]
        for index in range(slots):
            start = index * (1 << page_power)
            block = thin[start:min(start + (1 << page_power), code_limit)]
            target = cd + hash_offset + index * hash_size
            thin[target:target + hash_size] = digest(block).digest()[:hash_size]
    struct.pack_into(">I", binary, 8 + last_index * 20 + 12, len(thin))
    binary[base:] = thin
    return binary, base + old_size


def sign(app: Path, identifier: str) -> None:
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
        "--identifier", identifier, str(app))


def zip_ditto(app: Path, destination: Path) -> int:
    destination.unlink(missing_ok=True)
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
        str(app), str(destination))
    return destination.stat().st_size


def match_zip(app: Path, exe: Path, binary: bytearray, pad_start: int,
              destination: Path, desired: int) -> dict:
    """Tune inert signature allocation entropy; do not touch executable code."""
    room = len(binary) - pad_start
    require(room > 0, "ZIP matching needs unused executable padding.")
    seed_name = "slink-explicit-inert-size-ballast-v1"
    entropy = hashlib.shake_256(seed_name.encode()).digest(room)
    checks = 0

    def candidate(prefix: int, nonce: int = 0) -> int:
        nonlocal checks
        binary[pad_start:] = bytes(room)
        binary[pad_start:pad_start + prefix] = entropy[:prefix]
        if nonce:
            # Small deterministic replacement changes DEFLATE choices around
            # byte-size gaps without changing any parsed signature content.
            width = min(prefix, 64)
            binary[pad_start:pad_start + width] = hashlib.shake_256(
                f"{seed_name}:{nonce}".encode()).digest(width)
        exe.write_bytes(binary)
        checks += 1
        return zip_ditto(app, destination)

    minimum = candidate(0)
    require(minimum <= desired,
            f"Minimum archive ({minimum:,}) exceeds target ({desired:,}).")
    if minimum == desired:
        return {"method": "ditto", "entropyBytes": 0, "nonce": 0, "probes": checks}
    maximum = candidate(room)
    require(maximum >= desired,
            f"Maximum archive ({maximum:,}) cannot reach target ({desired:,}).")
    low, high = 0, room
    nearby = {}
    while high - low > 1:
        middle = (low + high) // 2
        size = candidate(middle)
        nearby[middle] = size
        if size == desired:
            return {"method": "ditto", "entropyBytes": middle, "nonce": 0,
                    "probes": checks, "minimumBytes": minimum, "maximumBytes": maximum}
        if size < desired:
            low = middle
        else:
            high = middle
    # DEFLATE size is not perfectly monotonic. Scan near the crossing and vary
    # a short deterministic nonce to avoid relying on ZIP comment padding.
    for prefix in range(max(0, low - 16), min(room, high + 16) + 1):
        for nonce in range(9):
            size = candidate(prefix, nonce)
            if size == desired:
                return {"method": "ditto", "entropyBytes": prefix, "nonce": nonce,
                        "probes": checks, "minimumBytes": minimum, "maximumBytes": maximum}
    # Any standard ZIP comment is valid inert metadata. This fallback is exact
    # for the distributed ZIP only, explicitly reported instead of claiming
    # ordinary re-compression has a matching size.
    prefix = low
    while True:
        size = candidate(prefix)
        if size <= desired:
            break
        prefix = max(0, prefix - max(1, size - desired))
    difference = desired - size
    require(difference <= 65535, "ZIP comment fallback exceeds standard ZIP limit.")
    with zipfile.ZipFile(destination, "a") as archive:
        archive.comment = b" " * difference
    require(destination.stat().st_size == desired, "ZIP fallback size mismatch.")
    return {"method": "ditto-plus-standard-ZIP-comment", "entropyBytes": prefix,
            "nonce": 0, "commentBytes": difference, "probes": checks,
            "minimumBytes": minimum, "maximumBytes": maximum}


def validate_extraction(app: Path, archive: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="slink-extract-") as directory:
        run("/usr/bin/ditto", "-x", "-k", str(archive), directory)
        extracted = Path(directory) / app.name
        require(file_manifest(extracted) == file_manifest(app),
                "Extracted app bytes differ from the packaged app.")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures",
            str(extracted))
        return zip_ditto(extracted, Path(directory) / "recompressed.zip")


def package(app: Path, destination: Path, report_path: Path, target_sizes: dict) -> dict:
    app, destination = app.resolve(), destination.resolve()
    desired_bundle = target_sizes["bundleLogicalBytes"]
    desired_exe = target_sizes["executableBytes"]
    desired_zip = target_sizes["zipBytes"]
    require(all(isinstance(value, int) and value > 0
                for value in (desired_bundle, desired_exe, desired_zip)),
            "Byte budgets must be positive integers.")
    exe = executable(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    require(identifier == "local.slink.sampling" or identifier.startswith("local.slink.sampling."),
            "Unexpected bundle identifier.")
    ballast = app / "Contents/Resources" / BALLAST_NAME
    ballast.parent.mkdir(parents=True, exist_ok=True)
    ballast.write_bytes(b"")
    # Resource seal length is stable for a fixed resource list. Iterate rather
    # than assume a platform-specific CodeResources XML size.
    for attempt in range(5):
        sign(app, identifier)
        other_size = sum(p.stat().st_size for p in bundle_files(app)
                         if p not in (exe, ballast))
        desired_ballast = desired_bundle - desired_exe - other_size
        require(desired_ballast >= 0, "Non-executable resources exceed size budget.")
        if ballast.stat().st_size == desired_ballast:
            break
        ballast.write_bytes(bytes(desired_ballast))
    else:
        raise RuntimeError("Resource seal byte count did not stabilize.")
    binary, pad_start = pad_adhoc_universal(exe.read_bytes(), desired_exe)
    exe.write_bytes(binary)
    require(logical_bytes(app) == desired_bundle, "Bundle logical byte count mismatch.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    matching = match_zip(app, exe, binary, pad_start, destination, desired_zip)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))
    require(exe.stat().st_size == desired_exe, "Executable size mismatch.")
    require(logical_bytes(app) == desired_bundle, "Final bundle size mismatch.")
    require(destination.stat().st_size == desired_zip, "Final ZIP size mismatch.")
    extracted_zip_bytes = validate_extraction(app, destination)
    with tempfile.TemporaryDirectory(prefix="slink-rezip-") as directory:
        normal_ditto_bytes = zip_ditto(app, Path(directory) / "slink.zip")
    report = {
        "formatVersion": 1,
        "targets": target_sizes,
        "output": {"app": str(app), "zip": str(destination),
                   "files": file_manifest(app), "zipSHA256": sha256(destination)},
        "matches": {"executableBytes": desired_exe, "bundleLogicalBytes": desired_bundle,
                    "zipBytes": desired_zip, "extractedBytesIdentical": True,
                    "extractedDittoZipBytes": extracted_zip_bytes,
                    "extractedDittoZipMatches": extracted_zip_bytes == desired_zip,
                    "strictAdHocSignatureValid": True,
                    "ordinaryDittoZipBytes": normal_ditto_bytes,
                    "ordinaryDittoZipMatches": normal_ditto_bytes == desired_zip},
        "ballast": {"resourceBytes": ballast.stat().st_size,
                    "signatureAllocationAddedBytes": len(binary) - pad_start,
                    "zipTuning": matching},
        "limitations": ["Bundle size means sum of regular-file logical byte sizes; allocation varies by filesystem.",
                        "Archive size is matched for the supplied ZIP and, when reported, the documented ditto command.",
                        "Other ZIP tools/settings/metadata may produce different sizes."]
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True,
                        help="JSON file containing the packaging byte budgets.")
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    arguments = parser.parse_args()
    target_sizes = json.loads(arguments.targets.read_text())
    report = package(arguments.app, arguments.zip, arguments.report, target_sizes)
    print(json.dumps(report["matches"], indent=2))


if __name__ == "__main__":
    main()
