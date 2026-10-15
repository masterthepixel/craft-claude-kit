#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and answer its prompts, so tests can exercise the interactive path.

  pty_drive.py [--answer y] [--quiet 1.5] [--max-answers 4] [--timeout 180] -- COMMAND [ARGS...]

The command gets a real controlling terminal (so `[ -t 0 ]` is true). Its output is copied to stdout. Whenever it
has been silent for --quiet seconds, one line (--answer, default "n") is typed, at most --max-answers times: enough
for "install the GUI apps?" and "go ahead?" prompts without knowing their wording or order. Exit status: the
command's, or 124 on timeout. Python 3.9+, standard library only.
"""
import argparse
import os
import select
import signal
import sys
import time


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--answer", default="n")
    p.add_argument("--quiet", type=float, default=1.5)
    p.add_argument("--max-answers", type=int, default=4)
    p.add_argument("--timeout", type=float, default=180.0)
    p.add_argument("command", nargs=argparse.REMAINDER)
    ns = p.parse_args(argv)
    cmd = ns.command[1:] if ns.command and ns.command[0] == "--" else ns.command
    if not cmd:
        p.error("no command given")

    import pty

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(cmd[0], cmd)
        except OSError as exc:
            sys.stderr.write("pty_drive: cannot run %s: %s\n" % (cmd[0], exc))
            os._exit(127)

    start = last = time.monotonic()
    answered = 0
    armed = True
    timed_out = False
    while True:
        ready, _, _ = select.select([fd], [], [], 0.25)
        now = time.monotonic()
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                data = b""
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            last = now
            armed = True
        else:
            if armed and answered < ns.max_answers and now - last >= ns.quiet:
                os.write(fd, (ns.answer + "\n").encode())
                answered += 1
                armed = False
        if now - start > ns.timeout:
            timed_out = True
            os.kill(pid, signal.SIGTERM)
            break
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        return 1
    if timed_out:
        return 124
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
