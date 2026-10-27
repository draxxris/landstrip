# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (c) 2026 Jarkko Sakkinen

import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


def children(pid):
    return Path(f"/proc/{pid}/task/{pid}/children").read_text().split()


def wait_for(predicate, message):
    deadline = time.monotonic() + 5
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(message)
        time.sleep(0.01)


if sys.argv[1:] == ["children"]:
    print("ready", flush=True)
    input()
    parent = os.fork()
    if parent == 0:
        signal.signal(signal.SIGUSR1, lambda *_: os._exit(0))
        signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGUSR1])
        for _ in range(8):
            if os.fork() == 0:
                signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGUSR1])
                while True:
                    signal.pause()
        signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGUSR1])
        os._exit(0)
    assert os.waitpid(parent, 0) == (parent, 0)
    print("orphaned", flush=True)
    input()
    sys.exit(37)
else:
    binary, policy = sys.argv[1:]
    with subprocess.Popen(
        [binary, "run", "-p", policy, "--", sys.executable, __file__, "children"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as broker:
        try:
            assert select.select([broker.stdout], [], [], 5)[0], "tool did not become ready"
            assert broker.stdout.readline() == "ready\n"
            init, = children(broker.pid)
            main, = children(init)
            os.kill(int(init), signal.SIGSTOP)
            wait_for(
                lambda: Path(f"/proc/{init}/stat").read_text().rsplit(") ", 1)[1].startswith("T"),
                "init did not stop",
            )
            broker.stdin.write("\n")
            broker.stdin.flush()
            assert select.select([broker.stdout], [], [], 5)[0], "tool did not orphan children"
            assert broker.stdout.readline() == "orphaned\n"
            wait_for(lambda: len(children(init)) == 9, "missing adopted children")
            orphans = [pid for pid in children(init) if pid != main]
            for index, pid in enumerate(orphans):
                os.kill(int(pid), signal.SIGUSR1 if index < 4 else signal.SIGKILL)
            wait_for(
                lambda: all(
                    Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].startswith("Z")
                    for pid in orphans
                ),
                "adopted children did not exit",
            )
            os.kill(int(init), signal.SIGCONT)
            wait_for(lambda: children(init) == [main], "init retained zombie children")
            assert broker.poll() is None
            broker.stdin.write("\n")
            broker.stdin.flush()
            assert broker.wait(timeout=5) == 37
        finally:
            if broker.poll() is None:
                broker.kill()
            broker.wait(timeout=5)
