import posix
import std/[os, strutils, paths]
import std/locks
import std/inotify

import logging
import dmontypes

proc watchRecursive(
    watch: WatchState, dirname: string, fd: FileHandle, mask: uint32, followLinks: bool
) =
  for kind, path in walkDir(dirname):
    var entryValid = false
    if kind == pcDir:
      if path.extractFilename notin [".", ".."]:
        entryValid = true
    elif followLinks and kind == pcLinkToDir:
      let realPath = expandSymlink(path)
      entryValid = true

    if entryValid:
      var watchDir = path
      if not watchDir.endsWith("/"):
        watchDir.add '/'

      let wd = inotify_add_watch(fd.cint, watchDir.cstring, mask.cuint)
      assert wd != -1, "Failed to add watch for " & watchDir

      var subdir = WatchSubdir(rootDir: watchDir)
      if subdir.rootDir.startsWith(watch.rootDir):
        subdir.rootDir = subdir.rootDir[watch.rootDir.len ..^ 1]

      watch.subdirs.add subdir
      watch.wds.add wd

      watch.watchRecursive(watchDir, fd, mask, followLinks)

proc findSubdir(watch: WatchState, wd: cint): string =
  for i, watchWd in watch.wds:
    if wd == watchWd:
      return watch.subdirs[i].rootDir
  return ""

proc unwatchState(watch: var WatchState) =
  if watch != nil:
    discard close(watch.fd)
    watch = nil

# Main watch function
proc watch*(
    rootDir: string,
    callback: WatchCallback,
    flags: set[WatchFlags] = {},
    userData: pointer = nil,
): WatchId =
  let watch = dmon.watchInit(rootdir, watchCb, flags, userData)

  withLock dmon.mutex:
    # Initialize inotify
    watch.fd = inotify_init().FileHandle
    if watch.fd.cint < 0:
      return WatchId(0)

    let inotifyMask =
      IN_MOVED_TO or IN_CREATE or IN_MOVED_FROM or IN_DELETE or IN_MODIFY
    let wd = inotify_add_watch(watch.fd.cint, watch.rootDir.cstring, inotifyMask.cuint)

    if wd < 0:
      return WatchId(0)

    watch.subdirs.add WatchSubdir(rootDir: "")
    watch.wds.add wd

    # Handle recursive watching if requested
    if wfRecursive in flags:
      watch.watchRecursive(
        watch.rootDir, watch.fd, inotifyMask.cuint, wfFollowSymlinks in flags
      )

    return id

# Unwatch a directory
proc unwatch*(id: WatchId) =
  assert dmonInitialized
  assert uint32(id) > 0

  let index = int(id) - 1
  assert index < 64
  assert dmon.watches[index] != nil
  assert dmon.numWatches > 0

  if dmon.watches[index] != nil:
    withLock dmon.mutex:
      discard close(dmon.watches[index].fd)
      dmon.watches[index] = nil

      dec dmon.numWatches
      let numFreeList = 64 - dmon.numWatches
      dmon.freeList[numFreeList - 1] = index
