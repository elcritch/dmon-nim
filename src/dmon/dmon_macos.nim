import std/os
import std/strutils
import std/locks
import std/strutils
import std/private/globs

import logging
import std/posix

# MacOS-specific imports
{.passL: "-framework CoreServices -framework CoreFoundation".}

import macosutils/cfcore
import macosutils/fsstream

import dmontypes

var
  dmonInitialized: bool
  dmon: DmonState

proc fsEventCallback(
    streamRef: FSEventStreamRef,
    userData: pointer,
    numEvents: csize_t,
    eventPaths: pointer,
    eventFlags: ptr FSEventStreamEventFlags,
    eventIds: ptr FSEventStreamEventId,
) {.cdecl.} =
  let watchId = cast[DmonWatchId](userData)
  assert(uint32(watchId) > 0)

  notice "fsEventCallback: ", numEvents = numEvents, watchId = watchId.int, streamRef = streamRef.pointer.repr
  let eventFlags = cast[ptr UncheckedArray[set[FSEventStreamEventFlag]]](eventFlags)
  let eventIds = cast[ptr UncheckedArray[FSEventStreamEventId]](eventFlags)

  let watch = dmon.watches[uint32(watchId) - 1]
  # we set 
  let paths = cast[cstringArray](eventPaths)

  for i in 0 ..< numEvents:
    let path = $paths[i]
    notice "fsEventCallback:event: ",
      i = i,
      eventIds = eventIds[i],
      eventFlags = eventFlags[i],
      watchId = watchId.int,
      path = path

    var ev = DmonFsEvent()
    # Convert path to unix style and make relative to watch root
    var absPath = nativeToUnixPath(path)
    let watchRoot = watch.rootdir.toLowerAscii

    if not absPath.isRelativeTo(watchRoot):
      notice "fsEventCallback:event:skipping ", absPath = absPath, watchRoot = watchRoot
      continue

    ev.filepath = absPath.relativePath(watchRoot)
    ev.eventFlags = eventFlags[i]
    ev.eventId = eventIds[i]
    ev.watchId = watchId

    notice "fsEventCallback:event:adding: ", ev = ev.repr
    dmon.events.add(ev)

proc processEvents(events: seq[DmonFsEvent]) =
  trace "processing processEvents ", eventsLen = dmon.events.len
  for i, ev in events:
    if ev.skip:
      continue

    # Coalesce multiple modify events
    if ev.eventFlags.contains(ItemModified):
      for checkEv in events[i+1..^1]:
        if checkEv.eventFlags.contains(ItemModified) and
            checkEv.filepath == ev.filepath:
          ev.skip = true
          break

    # Handle renames
    elif ev.eventFlags.contains(ItemRenamed) and not ev.moveValid:
      for checkEv in events[i+1..^1]:
        if checkEv.eventFlags.contains(ItemRenamed) and
            checkEv.eventId == ev.eventId + 1:
          ev.moveValid = true
          checkEv.moveValid = true
          break

      # If no matching rename found, treat as create/delete
      # // in some environments like finder file explorer:
      # // when a file is deleted, it is moved to recycle bin
      # // so if the destination of the move is not valid, it's probably DELETE or CREATE
      # // decide CREATE if file exists
      if not ev.moveValid:
        ev.eventFlags.excl ItemRenamed
        let watch = dmon.watches[ev.watchId.uint32 - 1]
        let absPath = watch.rootdir / ev.filepath

        if not fileExists(absPath):
          ev.eventFlags.incl ItemRemoved
        else:
          ev.eventFlags.incl ItemCreated

  # Process final events
  for i, ev in events:
    if ev.skip:
      trace "skipping event: ", i = i, ev = ev.repr
      continue

    let watch = dmon.watches[uint32(ev.watchId) - 1]
    if watch == nil or watch.watchCb == nil:
      continue

    if ev.eventFlags.contains(ItemCreated):
      watch.watchCb(
        ev.watchId, Create, watch.rootdirUnmod, ev.filepath, "", watch.userData
      )

    if ev.eventFlags.contains(ItemModified):
      watch.watchCb(
        ev.watchId, Modify, watch.rootdirUnmod, ev.filepath, "", watch.userData
      )
    elif ev.eventFlags.contains(ItemRenamed):
      for j in (i + 1) ..< dmon.events.len:
        let checkEv = addr dmon.events[j]
        if checkEv.eventFlags.contains(ItemRenamed):
          watch.watchCb(
            checkEv.watchId, Move, watch.rootdirUnmod, checkEv.filepath, ev.filepath,
            watch.userData,
          )
          break
    elif ev.eventFlags.contains(ItemRemoved):
      watch.watchCb(
        ev.watchId, Delete, watch.rootdirUnmod, ev.filepath, "", watch.userData
      )

proc monitorThread() {.thread.} =
  {.cast(gcsafe).}:
    notice "starting thread"
    dmon.cfLoopRef = CFRunLoopGetCurrent()
    withLock(dmon.threadLock):
      echo "signal lock"
      signal(dmon.threadSem) # dispatch_semaphore_signal(dmon.threadSem)

    notice "started thread loop"
    while not dmon.quit:
      if dmon.numWatches == 0:
        os.sleep(10)
        release(dmon.threadLock)
        # debug "monitorThread: no numWatches: "
        continue

      withLock(dmon.threadLock):
        # debug "processing watches ", numWatches = dmon.numWatches

        for watch in dmon.watchStates():
          if not watch.init:
            info "initialize watch ", watch = watch.repr
            assert(not watch.fsEvStreamRef.pointer.isNil)
            FSEventStreamScheduleWithRunLoop(
              watch.fsEvStreamRef, dmon.cfLoopRef, kCFRunLoopDefaultMode
            )
            let sres = FSEventStreamStart(watch.fsEvStreamRef)
            debug "initialized watch ", sres = sres.repr
            watch.init = true

        let res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false)
        trace "CFRunLoopRunInMode result: ", res = res
        processEvents(move dmon.events)
        assert dmon.events.len() == 0

      # release(dmon.threadLock)

    CFRunLoopStop(dmon.cfLoopRef)
    dmon.cfLoopRef = nil.CFRunLoopRef

proc unwatchState(watch: DmonWatchState) =
  if not watch.fsEvStreamRef.pointer.isNil:
    FSEventStreamStop(watch.fsEvStreamRef)
    FSEventStreamInvalidate(watch.fsEvStreamRef)
    FSEventStreamRelease(watch.fsEvStreamRef)
    watch.fsEvStreamRef = nil.FSEventStreamRef

proc initDmon*() =
  assert(not dmonInitialized)

  initLock(dmon.threadLock)
  initCond(dmon.threadSem)

  dmon.cfAllocRef = createBasicDefaultCFAllocator()
  echo "cfAllocRef: ", dmon.cfAllocRef.repr

  createThread(dmon.threadHandle, monitorThread)

  wait(dmon.threadSem, dmon.threadLock)
  notice "init dom"

  for i in 0 ..< 64:
    dmon.freeList[i] = 64 - i - 1

  dmonInitialized = true

proc deinitDmon*() =
  assert(dmonInitialized)

  dmon.quit = true
  joinThread(dmon.threadHandle)

  deinitCond(dmon.threadSem)
  deinitLock(dmon.threadLock)

  for i in 0 ..< dmon.numWatches:
    if dmon.watches[i] != nil:
      unwatchState(dmon.watches[i])

  dmon = DmonState()
  dmonInitialized = false

proc watchDmon*(
    dmon: var DmonState,
    rootdir: string,
    watchCb: DmonWatchCallback,
    flags: set[DmonWatchFlags],
    userData: pointer,
): DmonWatchId =
  # Create FSEvents stream
  let watch = dmon.watchDmonInit(rootdir, watchCb, flags, userData)

  withLock dmon.threadLock:
    let cfPath = CFStringCreateWithCString(
      nil.CFAllocatorRef, watch.rootdirUnmod.cstring, kCFStringEncodingUTF8
    )
    defer:
      CFRelease(cfPath.pointer)

    let cfPaths =
      CFArrayCreate(nil.CFAllocatorRef, cast[ptr pointer](unsafeAddr cfPath), 1, nil)
    defer:
      CFRelease(cfPaths.pointer)

    var ctx = FSEventStreamContext(
      version: 0,
      info: cast[pointer](watch.id),
      retain: nil,
      release: nil,
      copyDescription: nil,
    )
    let flags = {FileEvents, NoDefer}
    notice "FSEventStreamCreate: ", cfPaths = cfPaths.repr, flags = flags, fileevents = cast[uint]({FSEventStreamCreateFlag.FileEvents})
    assert cast[uint64]({FSEventStreamCreateFlag.FileEvents}) == 0x00000010'u32 
    watch.fsEvStreamRef = FSEventStreamCreate(
      dmon.cfAllocRef, # Use default allocator
      fsEventCallback, # Callback function
      addr ctx, # Context with watch ID
      cfPaths, # Array of paths to watch
      kFSEventStreamEventIdSinceNow, # Start from now
      # FSEventStreamEventId(0), # kFSEventStreamEventIdSinceNow, # Start from now
      0.25, # Latency in seconds
      flags.toBase(), # File-level events
    )

    if watch.fsEvStreamRef.pointer.isNil:
      warn "Failed to create FSEvents stream"
      dec dmon.numWatches
      raise newException(ValueError, "Exceeding maximum number of watches")

    notice "FSEventStreamCreated ", fsEvStreamRef = watch.fsEvStreamRef.pointer.repr
    # dmon.modifyWatches.store(0)
    result = DmonWatchId(watch.id)
    notice "watchDmon: done"

proc unwatchDmon*(id: DmonWatchId) =
  assert(dmonInitialized)
  assert(uint32(id) > 0)

  let index = int(uint32(id) - 1)
  assert(index < 64)
  assert(dmon.watches[index] != nil)
  assert(dmon.numWatches > 0)

  if dmon.watches[index] != nil:
    # dmon.modifyWatches.store(1)
    withLock dmon.threadLock:
      unwatchState(dmon.watches[index])
      dmon.watches[index] = nil

      dec dmon.numWatches
      let numFreeList = 64 - dmon.numWatches
      dmon.freeList[numFreeList - 1] = index

    # dmon.modifyWatches.store(0)

when isMainModule:
  let cb: DmonWatchCallback = proc(
      watchId: DmonWatchId,
      action: DmonAction,
      rootdir, filepath, oldfilepath: string,
      userData: pointer,
  ) {.gcsafe.} =
    echo "callback: ", "watchId: ", watchId.repr
    echo "callback: ", "action: ", action.repr
    echo "callback: ", "rootdir: ", rootdir.repr
    echo "callback: ", "file: ", filepath.repr
    echo "callback: ", "old: ", oldfilepath.repr

  initDmon()
  echo("waiting for changes ..")
  let args = commandLineParams()
  let root = 
    if args.len() == 0:
      "./tests/"
    else:
      args[0]
  discard dmon.watchDmon(root, cb, {Recursive}, nil)
  # discard watchDmon("/tmp/testmon/", cb, {Recursive}, nil)
  os.sleep(30_000)
  echo("done ..")
  deinitDmon()
