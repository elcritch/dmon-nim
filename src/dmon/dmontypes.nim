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

when defined(linux):
  type
    WatchSubdir* = object
      rootDir*: string

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
    rootDir, filepath, oldfilepath: string,
    userData: pointer,
  )

  FileEvent* = ref object of RootObj
    watchId*: WatchId
    filepath*: string
    skip*: bool
    when defined(macosx):
      eventId*: FSEventStreamEventId
      eventFlags*: set[FSEventStreamEventFlag]
      moveValid*: bool
    elif defined(linux):
      mask*: uint32
      cookie*: uint32

  WatchState* = ref object of RootObj
    id*: WatchId
    watchFlags*: set[WatchFlags]
    watchCb*: WatchCallback
    userData*: pointer
    rootDir*: string
    when defined(macosx):
      fsEvStreamRef*: FSEventStreamRef
      init*: bool
      rootDirUnmod*: string
    elif defined(linux):
      fd*: FileHandle
      subdirs*: seq[WatchSubdir]
      wds*: seq[cint]

  DmonState* = object
    initialized*: bool
    watches*: array[64, WatchState]
    freeList*: array[64, int]
    events*: seq[FileEvent]
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
    rootDir: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags],
    userData: pointer,
): WatchState =
  assert(dmon.initialized)
  assert(not rootDir.isEmptyOrWhitespace)
  assert(watchCb != nil)
  let rootDir = rootDir.absolutePath().expandFilename()

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
    if not dirExists(rootDir):
      warn "Could not open/read directory: ", rootDir
      dec dmon.numWatches
      # return WatchId(0)
      raise newException(KeyError, "could not open/read root directory: " & rootDir)

    # Handle symlinks
    var finalPath = rootDir
    if flags.contains(WatchFlags.FollowSymlinks):
      try:
        finalPath = expandSymlink(rootDir)
      except OSError:
        warn "Failed to resolve symlink: ", rootDir
        dec dmon.numWatches
        raise newException(ValueError, "Exceeding maximum number of watches")

    # Setup watch path
    watch.rootDir = finalPath.normalizedPath
    if not watch.rootDir.endsWith("/"):
      watch.rootDir.add "/"

    watch.rootDir = watch.rootDir.toLowerAscii

    result = watch
 
  notice "watchDmon: done"

var
  dmon*: DmonState

proc unwatchImpl*(id: WatchId, unwatchStateProc: proc (watch: var WatchState) {.nimcall.}) =
  assert(dmon.initialized)
  assert(uint32(id) > 0)

  let index = int(uint32(id) - 1)
  assert(index < 64)
  assert(dmon.watches[index] != nil)
  assert(dmon.numWatches > 0)

  if dmon.watches[index] != nil:
    notice "unwatch location", id = id.repr
    withLock dmon.threadLock:
      unwatchStateProc(dmon.watches[index])
      dmon.watches[index] = nil

      dec dmon.numWatches
      let numFreeList = 64 - dmon.numWatches
      dmon.freeList[numFreeList - 1] = index

  notice "unwatch done"

template unwatch*(id: WatchId) =
  mixin unwatchState
  unwatchImpl(id, unwatchState)

template initDmon*() =
  mixin initDmonImpl
  assert(not dmon.initialized)
  initLock(dmon.threadLock)
  initCond(dmon.threadSem)
  initDmonImpl()

template startDmonThread*() =
  mixin monitorThread
  createThread(dmon.threadHandle, monitorThread)

  withLock(dmon.threadLock):
    wait(dmon.threadSem, dmon.threadLock)

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

  dmon.events.setLen(0)
  dmon = DmonState()
