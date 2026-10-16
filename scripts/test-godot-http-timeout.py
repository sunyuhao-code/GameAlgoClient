#!/usr/bin/env python3
"""Exercise the real Godot transport against a TLS server that never responds."""

import os
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "godot"
PROBE = "res://tests/http_transport_timeout.gd"
MODES = ("timeout", "cancel", "destroy", "exit")


def fixture(context: ssl.SSLContext):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(8)
    received = threading.Event()
    errors = []

    def serve():
        try:
            raw, _ = listener.accept()
            raw.settimeout(5)
            with context.wrap_socket(raw, server_side=True) as connection:
                request = b""
                while b"\r\n\r\n" not in request:
                    chunk = connection.recv(4096)
                    if not chunk:
                        raise RuntimeError("client closed before sending complete HTTP headers")
                    request += chunk
                received.set()
                time.sleep(4)
        except Exception as error:  # surfaced after the Godot subprocess exits
            errors.append(repr(error))
        finally:
            listener.close()

    threading.Thread(target=serve, daemon=True).start()
    return listener.getsockname()[1], received, errors


def run_case(godot: str, context: ssl.SSLContext, certificate: Path, mode: str):
    port, received, errors = fixture(context)
    command = [
        godot,
        "--headless",
        "--path",
        str(PROJECT),
        "--script",
        PROBE,
        "--",
        mode,
        str(port),
        str(certificate),
    ]
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True, timeout=8)
    elapsed = time.monotonic() - started
    print(result.stdout, end="")
    print(result.stderr, end="")
    expected_marker = "HTTP_TRANSPORT_EXIT_READY" if mode == "exit" else "HTTP_TRANSPORT_RESULT"
    if result.returncode or expected_marker not in result.stdout:
        raise RuntimeError(f"{mode} probe failed with exit {result.returncode}")
    if not received.wait(0.5):
        raise RuntimeError(f"{mode} probe did not reach the TLS no-response fixture")
    if errors and not received.is_set():
        raise RuntimeError(f"{mode} TLS fixture failed: {errors}")
    if mode == "exit" and elapsed > 2.5:
        raise RuntimeError(f"app exit waited {elapsed:.3f}s for an in-flight request")


def main():
    godot = os.environ.get("GODOT_BIN") or shutil.which("godot")
    if not godot:
        raise SystemExit("GODOT_BIN is required, or godot must be on PATH")
    openssl = shutil.which("openssl")
    if not openssl:
        raise SystemExit("OpenSSL is required for the local TLS fixture")
    with tempfile.TemporaryDirectory(prefix="gamealgo-http-timeout-") as directory:
        work = Path(directory)
        certificate = work / "certificate.pem"
        key = work / "key.pem"
        subprocess.run(
            [
                openssl,
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(key),
                "-out",
                str(certificate),
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost,IP:127.0.0.1",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.maximum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate, key)
        for mode in MODES:
            run_case(godot, context, certificate, mode)
    print("Godot HTTP transport timeout contracts passed.")


if __name__ == "__main__":
    main()
