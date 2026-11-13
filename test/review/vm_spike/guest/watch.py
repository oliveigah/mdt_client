"""Waits up to SECONDS for an inotify event in FOLDER and prints what came."""
import ctypes
import os
import select
import sys

folder, seconds = sys.argv[1], float(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(0)
# IN_MODIFY | IN_MOVED_TO | IN_CREATE | IN_DELETE
libc.inotify_add_watch(fd, folder.encode(), 0x2 | 0x80 | 0x100 | 0x200)
print("watching", flush=True)
ready, _, _ = select.select([fd], [], [], seconds)
print("event" if ready else "no event")
