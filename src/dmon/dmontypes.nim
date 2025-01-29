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
elif defined(linux):
  type
    WatchSubdir* = object
      rootDir*: string
elif defined(windows) or defined(winTest):
  import winim/lean

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
    elif defined(linux) and not defined(winTest):
      mask*: uint32
      cookie*: uint32
    elif defined(windows) or defined(winTest):
      # filepath*: array[260, char]
      action*: DWORD

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
    elif defined(linux) and not defined(winTest):
      fd*: FileHandle
      subdirs*: seq[WatchSubdir]
      wds*: seq[cint]
    elif defined(windows) or defined(winTest):
      oldFilepath*: array[260, char]
      notifyFilter*: DWORD
      overlapped*: OVERLAPPED
      dirHandle*: HANDLE

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
    when defined(macosx) and not defined(winTest):
      cfLoopRef*: CFRunLoopRef
      cfAllocRef*: CFAllocatorRef

var
  dmonInst*: DmonState

iterator watchStates*(dm: DmonState): WatchState =
  for i in 0 ..< dm.numWatches:
    yield dm.watches[i]

proc watchInit*(
    rootDir: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags],
    userData: pointer,
): WatchState =
  assert(dmonInst.initialized)
  assert(not rootDir.isEmptyOrWhitespace)
  assert(watchCb != nil)
  let rootDir = rootDir.absolutePath().expandFilename()

  notice "watchDmon: starting"
  # dmonInst.modifyWatches.store(1)

  withLock dmonInst.threadLock:
    notice "setting up watches"
    assert(dmonInst.numWatches < 64)
    if dmonInst.numWatches >= 64:
      raise newException(ValueError, "Exceeding maximum number of watches")

    let numFreeList = 64 - dmonInst.numWatches
    let index = dmonInst.freeList[numFreeList - 1]
    let id = uint32(index + 1)

    if dmonInst.watches[index] == nil:
      dmonInst.watches[index] = WatchState()

    inc dmonInst.numWatches

    let watch: WatchState = dmonInst.watches[id - 1]
    watch.id = WatchId(id)
    watch.watchFlags = flags
    watch.watchCb = watchCb
    watch.userData = userData

    # Validate directory
    if not dirExists(rootDir):
      warn "Could not open/read directory: ", rootDir
      dec dmonInst.numWatches
      # return WatchId(0)
      raise newException(KeyError, "could not open/read root directory: " & rootDir)

    # Handle symlinks
    var finalPath = rootDir
    if flags.contains(WatchFlags.FollowSymlinks):
      try:
        finalPath = expandSymlink(rootDir)
      except OSError:
        warn "Failed to resolve symlink: ", rootDir
        dec dmonInst.numWatches
        raise newException(ValueError, "Exceeding maximum number of watches")

    # Setup watch path
    watch.rootDir = finalPath.normalizedPath
    if not watch.rootDir.endsWith("/"):
      watch.rootDir.add "/"

    when defined(macosx):
      watch.rootdirUnmod = watch.rootdir
    watch.rootDir = watch.rootDir.toLowerAscii

    result = watch
 
  notice "watchDmon: done"

template threadExec*() =
  notice "starting thread"
  withLock(dmonInst.threadLock):
    notice "signal lock"
    signal(dmonInst.threadSem) # dispatch_semaphore_signal(dmonInst.threadSem)

  notice "started thread loop"
  while not dmonInst.quit:
    if dmonInst.numWatches == 0:
      os.sleep(100)
      debug "monitorThread: no numWatches"
      continue

    # debug "processing watches ", numWatches = dmonInst.numWatches
    processWatches()

    os.sleep(100)


proc unwatchImpl*(id: WatchId, unwatchStateProc: proc (watch: var WatchState) {.nimcall.}) =
  assert(dmonInst.initialized)
  assert(uint32(id) > 0)

  let index = int(uint32(id) - 1)
  assert(index < 64)
  assert(dmonInst.watches[index] != nil)
  assert(dmonInst.numWatches > 0)

  if dmonInst.watches[index] != nil:
    notice "unwatch location", id = id.repr
    withLock dmonInst.threadLock:
      unwatchStateProc(dmonInst.watches[index])
      dmonInst.watches[index] = nil

      dec dmonInst.numWatches
      let numFreeList = 64 - dmonInst.numWatches
      dmonInst.freeList[numFreeList - 1] = index

  notice "unwatch done"

template unwatch*(id: WatchId) =
  mixin unwatchState
  unwatchImpl(id, unwatchState)

template initDmon*() =
  mixin initDmonImpl
  assert(not dmonInst.initialized)
  initLock(dmonInst.threadLock)
  initCond(dmonInst.threadSem)
  initDmonImpl()

template startDmonThread*() =
  mixin monitorThread
  createThread(dmonInst.threadHandle, monitorThread)

  withLock(dmonInst.threadLock):
    wait(dmonInst.threadSem, dmonInst.threadLock)

  for i in 0 ..< 64:
    dmonInst.freeList[i] = 64 - i - 1
  
  dmonInst.initialized = true

template deinitDmon*() =
  mixin unwatch

  dmonInst.quit = true
  joinThread(dmonInst.threadHandle)

  deinitCond(dmonInst.threadSem)
  deinitLock(dmonInst.threadLock)

  for i in 0 ..< dmonInst.numWatches:
    if dmonInst.watches[i] != nil:
      unwatchState(dmonInst.watches[i])

  dmonInst = DmonState()
