import std/os
import std/strutils
import std/locks
import std/strutils
import std/private/globs
import std/[os, paths]

import logging

type
  DmonWatchId* = distinct uint32

  DmonWatchFlags* = enum
    Recursive = 0x1
    FollowSymlinks = 0x2
    OutOfScopeLinks = 0x4
    IgnoreDirectories = 0x8

  DmonAction* = enum
    Create = 1
    Delete
    Modify
    Move

  DmonWatchCallback* = proc(
    watchId: DmonWatchId,
    action: DmonAction,
    rootdir, filepath, oldfilepath: string,
    userData: pointer,
  )

  DmonFsEvent* = ref object of RootObj
    filepath*: string
    watchId*: DmonWatchId
    skip*: bool

  DmonWatchState* = ref object of RootObj
    id*: DmonWatchId
    watchFlags*: set[DmonWatchFlags]
    watchCb*: DmonWatchCallback
    userData*: pointer
    rootdir*: string
    rootdirUnmod*: string
    init*: bool

  DmonState*[T] = object
    watches*: array[64, DmonWatchState]
    freeList*: array[64, int]
    events*: seq[DmonFsEvent]
    numWatches*: int
    threadHandle*: Thread[void]
    threadLock*: Lock
    threadSem*: Cond
    quit*: bool
    osState*: T

proc watchDmon*(
    dmon: var DmonState,
    rootdir: string,
    watchCb: DmonWatchCallback,
    flags: set[DmonWatchFlags],
    userData: pointer,
): DmonWatchId =
  assert(not rootdir.isEmptyOrWhitespace)
  assert(watchCb != nil)
  let rootdir = rootdir.absolutePath().expandFilename()

  notice "watchDmon: starting"
  # dmon.modifyWatches.store(1)

  withLock dmon.threadLock:
    notice "adding watches"
    assert(dmon.numWatches < 64)
    if dmon.numWatches >= 64:
      notice "Exceeding maximum number of watches"
      return DmonWatchId(0)

    let numFreeList = 64 - dmon.numWatches
    let index = dmon.freeList[numFreeList - 1]
    let id = uint32(index + 1)

    if dmon.watches[index] == nil:
      dmon.watches[index] = DmonWatchState()

    inc dmon.numWatches

    let watch = dmon.watches[id - 1]
    watch.id = DmonWatchId(id)
    watch.watchFlags = flags
    watch.watchCb = watchCb
    watch.userData = userData

    # Validate directory
    if not dirExists(rootdir):
      warn "Could not open/read directory: ", rootdir
      dec dmon.numWatches
      # return DmonWatchId(0)
      raise newException(KeyError, "could not open/read root directory: " & rootdir)

    # Handle symlinks
    var finalPath = rootdir
    if flags.contains(DmonWatchFlags.FollowSymlinks):
      try:
        finalPath = expandSymlink(rootdir)
      except OSError:
        warn "Failed to resolve symlink: ", rootdir
        dec dmon.numWatches
        return DmonWatchId(0)

    # Setup watch path
    watch.rootdir = finalPath.normalizedPath
    if not watch.rootdir.endsWith("/"):
      watch.rootdir.add "/"

    watch.rootdir = watch.rootdir.toLowerAscii

    
  notice "watchDmon: done"
