#!/usr/bin/env python3
"""Run against a built KeyHopMenu binary; uses disposable localhost/PTY fixtures.

python3 apps/macos/Tests/cli_pty_integration.py apps/macos/.build/debug/KeyHopMenu
"""
import datetime
import fcntl
import json
import os
import pathlib
import pty
import select
import socket
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="keyhop-cli-pty-") as directory:
        root = pathlib.Path(directory)
        (root / "requests").mkdir()
        probe = root / "interactive-probe"
        probe.write_text("#!/bin/sh\nprintf 'READY\\n'\nIFS= read -r value\nprintf 'RECEIVED:%s\\n' \"$value\"\nprintf 'PROXY:%s\\n' \"$HTTPS_PROXY\"\nprintf 'OTHER_PROXY:%s|%s|%s|%s\\n' \"$HTTP_PROXY\" \"$ALL_PROXY\" \"$https_proxy\" \"$no_proxy\"\n")
        probe.chmod(0o700)
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        port = server.getsockname()[1]
        stopping = threading.Event()

        def respond():
            server.settimeout(0.2)
            while not stopping.is_set():
                try:
                    client, _ = server.accept()
                except socket.timeout:
                    continue
                with client:
                    client.settimeout(2)
                    data = b""
                    while b"\r\n\r\n" not in data:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                    assert data.startswith(b"CONNECT example.com:443 HTTP/1.1")
                    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")

        thread = threading.Thread(target=respond, daemon=True)
        thread.start()
        environment = dict(os.environ, KEYHOP_HOME=str(root))
        profile = {"id": "pty-probe", "name": "PTY probe", "kind": "cli", "path": str(probe), "arguments": [], "launchMethod": "environment"}
        proxy = {"enabled": True, "protocol": "http", "host": "127.0.0.1", "port": port, "bypass": ["localhost"]}

        def request():
            request_id = str(uuid.uuid4()).upper()
            document = {"id": request_id, "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "profile": profile, "configuration": {"version": 1, "proxy": proxy, "profiles": [profile]}, "launchPath": os.environ.get("PATH", "/usr/bin:/bin")}
            (root / "requests" / (request_id + ".json")).write_text(json.dumps(document))
            return request_id

        def start(request_id):
            master, slave = pty.openpty()
            def controlling_terminal():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            process = subprocess.Popen([binary, "--run-cli", request_id], env=environment, stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal)
            os.close(slave)
            return process, master

        def read_until(fd, marker, timeout=5):
            output = b""
            deadline = time.monotonic() + timeout
            while marker not in output and time.monotonic() < deadline:
                if select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
            assert marker in output, repr(output)
            return output

        def receipt(request_id):
            path = root / "receipts" / (request_id + ".json")
            deadline = time.monotonic() + 3
            while not path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            return json.loads(path.read_text())

        def drain_and_wait(process, fd, timeout=5):
            # macOS drains the session leader's tty before completing exit;
            # keep consuming output just as Terminal.app does.
            deadline = time.monotonic() + timeout
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        os.read(fd, 4096)
                    except OSError:
                        break
            return process.wait(timeout=max(0.1, deadline - time.monotonic()))

        first = request()
        process, master = start(first)
        try:
            read_until(master, b"READY")
            assert receipt(first)["state"] == "launched"
            duplicate = subprocess.run([binary, "--run-cli", first], env=environment, capture_output=True, timeout=3)
            assert duplicate.returncode == 1
            assert receipt(first)["state"] == "launched", "duplicate helper overwrote the real receipt"
            second = request()
            competing = subprocess.run([binary, "--run-cli", second], env=environment, capture_output=True, timeout=3)
            assert competing.returncode == 1
            assert receipt(second)["state"] == "alreadyRunning"
            os.write(master, b"keyboard works\n")
            output = read_until(master, f"PROXY:http://127.0.0.1:{port}".encode())
            assert b"RECEIVED:keyboard works" in output
            try:
                assert drain_and_wait(process, master) == 0
            except subprocess.TimeoutExpired:
                diagnostics = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=,command="], capture_output=True, text=True)
                print("PTY diagnostics:", "\n".join(line for line in diagnostics.stdout.splitlines() if directory in line or str(process.pid) in line), flush=True)
                print("Receipt:", receipt(first), flush=True)
                raise
            assert receipt(first)["state"] == "exited"
            assert receipt(first)["trafficVerified"] is False
        finally:
            if process.poll() is None:
                process.kill()
            os.close(master)

        # A disabled proxy must neither probe the unavailable endpoint nor
        # leak proxy settings inherited from Terminal into the child CLI.
        proxy["enabled"] = False
        proxy["port"] = 1
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "https_proxy", "no_proxy"):
            environment[key] = "inherited-proxy-must-not-leak"
        direct = request()
        process, master = start(direct)
        try:
            read_until(master, b"READY")
            assert receipt(direct)["state"] == "launched"
            assert receipt(direct).get("proxy") is None
            os.write(master, b"direct keyboard works\n")
            output = read_until(master, b"OTHER_PROXY:|||")
            assert b"PROXY:\r\n" in output
            assert b"inherited-proxy-must-not-leak" not in output
            assert drain_and_wait(process, master) == 0
            assert receipt(direct)["state"] == "exited"
            assert receipt(direct).get("proxy") is None
        finally:
            if process.poll() is None:
                process.kill()
            os.close(master)

        proxy["enabled"] = True
        proxy["port"] = port
        interrupted = request()
        process, master = start(interrupted)
        try:
            read_until(master, b"READY")
            os.write(master, b"\x03")
            assert drain_and_wait(process, master) != 0
            assert receipt(interrupted)["state"] == "exited"
        finally:
            if process.poll() is None:
                process.kill()
            os.close(master)
            stopping.set()
            thread.join(timeout=1)
            server.close()
        print("PASS: CLI keyboard input, optional proxy environment, disabled proxy without service, Ctrl-C, duplicate request receipt, concurrent profile lock")


if __name__ == "__main__":
    main()
