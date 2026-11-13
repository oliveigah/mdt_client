#!/usr/bin/env python3
"""Times ordinary file work in a folder. Runs anywhere with python3 and git,
so the same file gives numbers for the host, the spike VM and an msb VM:

    python3 files_bench.py /path/to/a/shared/folder

It works in a new subfolder and removes it at the end."""
import os
import shutil
import subprocess
import sys
import time

base = os.path.join(sys.argv[1], f"files-bench-{os.getpid()}")
tree = os.path.join(base, "tree")
git = ["git", "-C", tree, "-c", "user.name=bench", "-c", "user.email=bench@invalid", "-c", "commit.gpgsign=false",
       "-c", "safe.directory=*"]  # fmt: skip


def step(name, work):
    started = time.monotonic()
    work()
    print(f"{name}\t{time.monotonic() - started:.3f}", flush=True)


def create():
    for folder in range(500):
        os.makedirs(os.path.join(tree, f"d{folder}"))
        for index in range(20):
            with open(os.path.join(tree, f"d{folder}", f"f{index}.ex"), "w") as file:
                file.write(f"defmodule M{folder}_{index} do\nend\n" * 20)


def commit():
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "start"], check=True)


def status():
    subprocess.run(git + ["status", "--porcelain"], check=True, stdout=subprocess.DEVNULL)


def drop_caches():
    try:
        with open("/proc/sys/vm/drop_caches", "w") as file:
            file.write("3\n")
    except OSError:
        pass


def read_all():
    for folder, _, names in os.walk(tree):
        if ".git" in folder:
            continue
        for name in names:
            with open(os.path.join(folder, name), "rb") as file:
                file.read()


def write_big():
    chunk = bytes(1024 * 1024)
    with open(os.path.join(base, "big"), "wb") as file:
        for _ in range(1024):
            file.write(chunk)
        file.flush()
        os.fsync(file.fileno())


def read_big():
    with open(os.path.join(base, "big"), "rb") as file:
        while file.read(1024 * 1024):
            pass


os.makedirs(base)
try:
    step("create 10,000 files in 500 folders", create)
    step("git init, add, commit", commit)
    step("git status", status)
    step("git status again", status)
    drop_caches()
    step("read the 10,000 files", read_all)
    step("write 1 GiB and fsync", write_big)
    drop_caches()
    step("read the 1 GiB back", read_big)
    step("remove everything", lambda: shutil.rmtree(base))
finally:
    shutil.rmtree(base, ignore_errors=True)
