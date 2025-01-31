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


proc fsEventCallback(
    streamRef: FSEventStreamRef,
    userData: pointer,
    numEvents: csize_t,
    eventPaths: pointer,
    eventFlags: ptr FSEventStreamEventFlags,
    eventIds: ptr FSEventStreamEventId,
) {.cdecl.} =
  let watchId = cast[WatchId](userData)
  assert(uint32(watchId) > 0)

  debug "fsEventCallback: ", numEvents = numEvents, watchId = watchId.int, streamRef = streamRef.pointer.repr
  let eventFlags = cast[ptr UncheckedArray[set[FSEventStreamEventFlag]]](eventFlags)
  let eventIds = cast[ptr UncheckedArray[FSEventStreamEventId]](eventFlags)

  let watch = dmonInst.watches[uint32(watchId) - 1]
  # we set 
  let paths = cast[cstringArray](eventPaths)

  for i in 0 ..< numEvents:
    let path = $paths[i]
    debug "fsEventCallback:event: ",
      i = i,
      eventIds = eventIds[i],
      eventFlags = eventFlags[i],
      watchId = watchId.int,
      path = path

    var ev = FileEvent()
    # Convert path to unix style and make relative to watch root
    var absPath = nativeToUnixPath(path)
    let watchRoot = watch.rootDir.toLowerAscii

    if not absPath.isRelativeTo(watchRoot):
      debug "fsEventCallback:event:skipping ", absPath = absPath, watchRoot = watchRoot
      continue

    ev.filepath = absPath.relativePath(watchRoot)
    ev.eventFlags = eventFlags[i]
    ev.eventId = eventIds[i]
    ev.watchId = watchId

    debug "fsEventCallback:event:adding: ", ev = ev.repr
    dmonInst.events.add(ev)
    debug "fsEventCallback:events: ", dmonInst = dmonInst.addr.pointer.repr, events = dmonInst.events.repr

proc processEvents(events: seq[FileEvent]) =
  debug "processEvents: processing ", eventsLen = events.len

  for i, ev in events:
    if ev.skip:
      debug "processEvents:skip", ev= ev.repr
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
        let watch = dmonInst.watches[ev.watchId.uint32 - 1]
        let absPath = watch.rootDir / ev.filepath

        if not fileExists(absPath):
          ev.eventFlags.incl ItemRemoved
        else:
          ev.eventFlags.incl ItemCreated

  # Process final events
  for i, ev in events:
    if ev.skip:
      trace "skipping event: ", i = i, ev = ev.repr
      continue

    let watch = dmonInst.watches[uint32(ev.watchId) - 1]
    if watch == nil or watch.watchCb == nil:
      continue

    if ev.eventFlags.contains(ItemCreated):
      watch.watchCb(
        ev.watchId, Create, watch.rootDirUnmod, ev.filepath, "", watch.userData
      )

    if ev.eventFlags.contains(ItemModified):
      watch.watchCb(
        ev.watchId, Modify, watch.rootDirUnmod, ev.filepath, "", watch.userData
      )
    elif ev.eventFlags.contains(ItemRenamed):
      for j in (i + 1) ..< events.len:
        let checkEv = addr events[j]
        if checkEv.eventFlags.contains(ItemRenamed):
          watch.watchCb(
            checkEv.watchId, Move, watch.rootDirUnmod, checkEv.filepath, ev.filepath,
            watch.userData,
          )
          break
    elif ev.eventFlags.contains(ItemRemoved):
      watch.watchCb(
        ev.watchId, Delete, watch.rootDirUnmod, ev.filepath, "", watch.userData
      )

proc processWatches() =
  withLock(dmonInst.threadLock):
    for watch in dmonInst.watchStates():
      if not watch.init:
        info "initialize watch ", watch = watch.repr
        assert(not watch.fsEvStreamRef.pointer.isNil)
        FSEventStreamScheduleWithRunLoop(
          watch.fsEvStreamRef, dmonInst.cfLoopRef, kCFRunLoopDefaultMode
        )
        let sres = FSEventStreamStart(watch.fsEvStreamRef)
        debug "initialized watch ", sres = sres.repr
        watch.init = true

    let res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false)
    trace "CFRunLoopRunInMode result: ", res = res, events = dmonInst.events.repr
    if dmonInst.events.len() > 0:
      processEvents(move dmonInst.events)
    assert dmonInst.events.len() == 0

proc monitorThread*() {.thread.} =
  {.cast(gcsafe).}:
    notice "starting thread"
    dmonInst.cfLoopRef = CFRunLoopGetCurrent()

    threadExec()

    CFRunLoopStop(dmonInst.cfLoopRef)
    dmonInst.cfLoopRef = nil.CFRunLoopRef

proc unwatchState*(watch: var WatchState) =
  if not watch.fsEvStreamRef.pointer.isNil:
    FSEventStreamStop(watch.fsEvStreamRef)
    FSEventStreamInvalidate(watch.fsEvStreamRef)
    FSEventStreamRelease(watch.fsEvStreamRef)
    watch.fsEvStreamRef = nil.FSEventStreamRef
    watch = nil

proc watch*(
    rootDir: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags],
    userData: pointer,
): WatchId =
  ## Create Dmon watch using FSEvents stream
  let watch = watchInit(rootDir, watchCb, flags, userData)
  notice "Watch:Created: ", watch = watch.repr

  withLock dmonInst.threadLock:
    let cfPath = CFStringCreateWithCString(
      nil.CFAllocatorRef, watch.rootDirUnmod.cstring, kCFStringEncodingUTF8
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
      dmonInst.cfAllocRef, # Use default allocator
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
      dec dmonInst.numWatches
      raise newException(ValueError, "Exceeding maximum number of watches")

    notice "FSEventStreamCreated ", fsEvStreamRef = watch.fsEvStreamRef.pointer.repr
    # dmonInst.modifyWatches.store(0)
    result = WatchId(watch.id)
    notice "watchDmon: done"

proc initDmonImpl*() =
  dmonInst.cfAllocRef = createBasicDefaultCFAllocator()
  info "initDmonImpl: ", cfAllocRef = dmonInst.cfAllocRef.repr

