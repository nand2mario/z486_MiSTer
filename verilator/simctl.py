#!/usr/bin/env python3

import argparse
import socket
import sys


def receive_line(stream) -> str:
    response = stream.readline()
    if not response:
        raise ConnectionError("simulator closed the control connection")
    return response.decode("utf-8", errors="replace").rstrip("\r\n")


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
