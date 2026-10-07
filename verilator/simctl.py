#!/usr/bin/env python3

import argparse
import re
import socket
import sys
import time


def receive_line(stream) -> str:
    response = stream.readline()
    if not response:
        raise ConnectionError("simulator closed the control connection")
    return response.decode("utf-8", errors="replace").rstrip("\r\n")


def sim_time(connection, stream) -> int:
    connection.sendall(b"status\n")
    match = re.search(r"sim_time=(\d+)", receive_line(stream))
    if not match:
        raise ConnectionError("unexpected status reply")
    return int(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send streaming PS/2 and harness commands to z486_MiSTer simulation"
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9386)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port)) as connection:
        stream = connection.makefile("rb")
        if args.command:
            connection.sendall((" ".join(args.command) + "\n").encode())
            print(receive_line(stream))
            return 0

        for line in sys.stdin:
            words = line.split()
            # wait <sim_time>: block until the simulator has advanced that far
            # (client side, polling status), so key sequences can be paced.
            if len(words) == 2 and words[0] == "wait":
                start = sim_time(connection, stream)
                while sim_time(connection, stream) < start + int(words[1]):
                    time.sleep(1)
                print(f"waited {words[1]}", flush=True)
                continue
            if not line.endswith("\n"):
                line += "\n"
            connection.sendall(line.encode())
            print(receive_line(stream), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ConnectionError, OSError) as error:
        print(f"simctl: {error}", file=sys.stderr)
        raise SystemExit(1)
