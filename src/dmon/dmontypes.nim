import std/os
import std/strutils
import std/locks
import std/strutils
import std/private/globs
import std/[os, paths]

import logging

when defined(macosx):
  import macosutils/cfcore
  import macosutils/fsstream

type
  WatchId* = distinct uint32

  WatchFlags* = enum
    Recursive = 0x1
    FollowSymlinks = 0x2
    OutOfScopeLinks = 0x4
    IgnoreDirectories = 0x8

  DmonAction* {.pure.} = enum
    Create = 1
    Delete
    Modify
    Move

  WatchCallback* = proc(
    watchId: WatchId,
    action: DmonAction,
    rootdir, filepath, oldfilepath: string,
    userData: pointer,
  )

  FsEvent* = ref object of RootObj
    filepath*: string
    watchId*: WatchId
    skip*: bool
    when defined(macosx):
      eventId*: FSEventStreamEventId
      eventFlags*: set[FSEventStreamEventFlag]
      moveValid*: bool

  WatchState* = ref object of RootObj
    id*: WatchId
    watchFlags*: set[WatchFlags]
    watchCb*: WatchCallback
    userData*: pointer
    rootdir*: string
    rootdirUnmod*: string
    init*: bool
    when defined(macosx):
      fsEvStreamRef*: FSEventStreamRef

  DmonState* = object
    initialized*: bool
    watches*: array[64, WatchState]
    freeList*: array[64, int]
    events*: seq[FsEvent]
    numWatches*: int
    threadHandle*: Thread[void]
    threadLock*: Lock
    threadSem*: Cond
    quit*: bool
    when defined(macosx):
      cfLoopRef*: CFRunLoopRef
      cfAllocRef*: CFAllocatorRef

iterator watchStates*(dmon: DmonState): WatchState =
  for i in 0 ..< dmon.numWatches:
    yield dmon.watches[i]

proc watchInit*(
    dmon: var DmonState,
    rootdir: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags],
    userData: pointer,
): WatchState =
  assert(dmon.initialized)
  assert(not rootdir.isEmptyOrWhitespace)
  assert(watchCb != nil)
  let rootdir = rootdir.absolutePath().expandFilename()

  notice "watchDmon: starting"
  # dmon.modifyWatches.store(1)

  withLock dmon.threadLock:
    notice "setting up watches"
    assert(dmon.numWatches < 64)
    if dmon.numWatches >= 64:
      raise newException(ValueError, "Exceeding maximum number of watches")

    let numFreeList = 64 - dmon.numWatches
    let index = dmon.freeList[numFreeList - 1]
    let id = uint32(index + 1)

    if dmon.watches[index] == nil:
      dmon.watches[index] = WatchState()

    inc dmon.numWatches

    let watch: WatchState = dmon.watches[id - 1]
    watch.id = WatchId(id)
    watch.watchFlags = flags
    watch.watchCb = watchCb
    watch.userData = userData

    # Validate directory
    if not dirExists(rootdir):
      warn "Could not open/read directory: ", rootdir
      dec dmon.numWatches
      # return WatchId(0)
      raise newException(KeyError, "could not open/read root directory: " & rootdir)

    # Handle symlinks
    var finalPath = rootdir
    if flags.contains(WatchFlags.FollowSymlinks):
      try:
        finalPath = expandSymlink(rootdir)
      except OSError:
        warn "Failed to resolve symlink: ", rootdir
        dec dmon.numWatches
        raise newException(ValueError, "Exceeding maximum number of watches")

    # Setup watch path
    watch.rootdir = finalPath.normalizedPath
    if not watch.rootdir.endsWith("/"):
      watch.rootdir.add "/"

    watch.rootdir = watch.rootdir.toLowerAscii

    result = watch
 
  notice "watchDmon: done"

var
  dmon*: DmonState

template unwatch*(id: WatchId) =
  mixin unwatchState
  assert(dmon.initialized)
  assert(uint32(id) > 0)

  let index = int(uint32(id) - 1)
  assert(index < 64)
  assert(dmon.watches[index] != nil)
  assert(dmon.numWatches > 0)

  if dmon.watches[index] != nil:
    notice "unwatch location", id = id.repr
    withLock dmon.threadLock:
      unwatchState(dmon.watches[index])
      dmon.watches[index] = nil

      dec dmon.numWatches
      let numFreeList = 64 - dmon.numWatches
      dmon.freeList[numFreeList - 1] = index

  notice "unwatch done"

template initDmon*() =
  mixin initDmonImpl
  initLock(dmon.threadLock)
  initCond(dmon.threadSem)
  initDmonImpl()

template startDmonThread*() =
  mixin monitorThread
  createThread(dmon.threadHandle, monitorThread)

  notice "start dmon"

  withLock(dmon.threadLock):
    wait(dmon.threadSem, dmon.threadLock)
  notice "dmon started"

  for i in 0 ..< 64:
    dmon.freeList[i] = 64 - i - 1
  
  dmon.initialized = true

template deinitDmon*() =
  mixin unwatch

  dmon.quit = true
  joinThread(dmon.threadHandle)

  deinitCond(dmon.threadSem)
  deinitLock(dmon.threadLock)

  for i in 0 ..< dmon.numWatches:
    if dmon.watches[i] != nil:
      unwatchState(dmon.watches[i])

  dmon = DmonState()
