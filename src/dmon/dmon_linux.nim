import posix
import std/[os, strutils, paths]
import std/locks
import std/inotify
# import std/times
from std/times import getTime, Time

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

# Process inotify events
proc processEvents(events: seq[FileEvent]) =
  trace "processing processEvents ", eventsLen = dmon.events.len()
  for i, ev in events:
    var ev = events[i]
    if ev.skip:
      continue

    # Handle MODIFY events
    if (ev.mask and IN_MODIFY) != 0:
      # Coalesce multiple MODIFY events
      for j in (i+1)..<events.len:
        let checkEv = events[j]
        if (checkEv.mask and IN_MODIFY) != 0 and ev.filePath == checkEv.filePath:
          ev.skip = true
          break
        elif (ev.mask and IN_ISDIR) != 0 and (checkEv.mask and (IN_ISDIR or IN_MODIFY)) != 0:
          # Handle directory modifications
          var evPath = ev.filePath.strip(trailing = true, chars = {'/'})
          var checkPath = checkEv.filePath.strip(trailing = true, chars = {'/'})
          if evPath == checkPath:
            ev.skip = true
            break

    # Handle CREATE events
    elif (ev.mask and IN_CREATE) != 0:
      block outer:
        for j in (i+1)..<events.len:
          let checkEv = events[j]
          if (checkEv.mask and IN_MOVED_FROM) != 0 and ev.filePath == checkEv.filePath:
            # Look for matching MOVED_TO event
            for k in (j+1)..<events.len:
              let thirdEv = events[k]
              if (thirdEv.mask and IN_MOVED_TO) != 0 and checkEv.cookie == thirdEv.cookie:
                thirdEv.mask = IN_MODIFY
                ev.skip = true
                checkEv.skip = true
                break outer
          elif (checkEv.mask and IN_MODIFY) != 0 and ev.filePath == checkEv.filePath:
            checkEv.skip = true
            
    # Handle MOVED_FROM events
    elif (ev.mask and IN_MOVED_FROM) != 0:
      var moveValid = false
      for j in (i+1)..<events.len:
        let checkEv = events[j]
        if (checkEv.mask and IN_MOVED_TO) != 0 and ev.cookie == checkEv.cookie:
          moveValid = true
          break
      if not moveValid:
        ev.mask = IN_DELETE

    # Handle MOVED_TO events
    elif (ev.mask and IN_MOVED_TO) != 0:
      var moveValid = false
      for j in 0..<i:
        let checkEv = events[j]
        if (checkEv.mask and IN_MOVED_FROM) != 0 and ev.cookie == checkEv.cookie:
          moveValid = true
          break
      if not moveValid:
        ev.mask = IN_CREATE

    # Handle DELETE events
    elif (ev.mask and IN_DELETE) != 0:
      for j in (i+1)..<events.len:
        let checkEv = events[j]
        if (checkEv.mask and IN_MODIFY) != 0 and ev.filePath == checkEv.filePath:
          checkEv.skip = true
          break

  # Process the events
  for i in 0..<events.len:
    let ev = events[i]
    if ev.skip:
      trace "skipping event: ", i = i, ev = ev.repr
      continue

    let watch = dmon.watches[uint32(ev.watchId) - 1]
    if watch == nil or watch.watchCb == nil:
      continue

    if (ev.mask and IN_CREATE) != 0:
      if (ev.mask and IN_ISDIR) != 0 and Recursive in watch.watchFlags:
        var watchDir = watch.rootDir & ev.filePath & "/"
        let inotifyMask = IN_MOVED_TO or IN_CREATE or IN_MOVED_FROM or IN_DELETE or IN_MODIFY
        
        let wd = inotify_add_watch(watch.fd.cint, watchDir.cstring, inotifyMask.cuint)
        assert wd != -1

        var subdir = WatchSubdir(rootDir: watchDir)
        if subdir.rootDir.startsWith(watch.rootDir):
          subdir.rootDir = subdir.rootDir[watch.rootDir.len..^1]

        watch.subdirs.add subdir
        watch.wds.add wd

      watch.watchCb(ev.watchId, Create, watch.rootDir, ev.filePath, "", watch.userData)

    elif (ev.mask and IN_MODIFY) != 0:
      watch.watchCb(ev.watchId, Modify, watch.rootDir, ev.filePath, "", watch.userData)

    elif (ev.mask and IN_MOVED_FROM) != 0:
      for j in (i+1)..<dmon.events.len:
        let checkEv = addr dmon.events[j]
        if (checkEv.mask and IN_MOVED_TO) != 0 and ev.cookie == checkEv.cookie:
          watch.watchCb(checkEv.watchId, Move, watch.rootDir,
                       checkEv.filePath, ev.filePath, watch.userData)
          break

    elif (ev.mask and IN_DELETE) != 0:
      watch.watchCb(ev.watchId, Delete, watch.rootDir, ev.filePath, "", watch.userData)

  dmon.events.setLen(0)

proc monitorThread() {.thread.} =
  const BufferSize = sizeof(InotifyEvent) * 1024
  var buffer: array[BufferSize, byte]
  
  var startTime: times.Time
  var microSecsElapsed: int64 = 0
  startTime = getTime()

  while not dmon.quit:
    if dmon.numWatches == 0:
      os.sleep(100)
      # debug "monitorThread: no numWatches: "
      continue
      

    withLock(dmon.threadLock):
      var readfds: TFdSet
      FD_ZERO(readfds)
      
      # Add all watch file descriptors to the set
      for i in 0..<dmon.numWatches:
        let watch = dmon.watches[i]
        if watch != nil:
          FD_SET(watch.fd.cint, readfds)

      var timeout: Timeval
      timeout.tv_sec = Time(0)
      timeout.tv_usec = Suseconds(100_000) # 100ms timeout

      if select(FD_SETSIZE, addr readfds, nil, nil, addr timeout) > 0:
        for i in 0..<dmon.numWatches:
          let watch = dmon.watches[i]
          if watch != nil and FD_ISSET(watch.fd.cint, readfds):
            var offset = 0
            let bytesRead = read(watch.fd.cint, addr buffer[0], BufferSize)
            
            if bytesRead <= 0:
              continue

            while offset < bytesRead:
              let iev = cast[ptr InotifyEvent](addr buffer[offset])
              let subdir = watch.findSubdir(iev.wd)
              
              if subdir.len > 0:
                let filepath = subdir & $cast[cstring](addr buffer[offset + sizeof(InotifyEvent)])
                
                if dmon.events.len == 0:
                  microSecsElapsed = 0
                  
                var event = InotifyEvent(
                  filePath: filepath,
                  mask: iev.mask,
                  cookie: iev.cookie,
                  watchId: watch.id,
                  skip: false
                )
                dmon.events.add(event)

              offset += sizeof(InotifyEvent) + iev.len

      # Check elapsed time and process events if needed
      let currentTime = getTime()
      let dt = (currentTime - startTime).inMicroseconds
      startTime = currentTime
      microSecsElapsed += dt
      
      if microSecsElapsed > 100_000 and dmon.events.len > 0:
        processEvents()
        microSecsElapsed = 0

    sleep(10) # Sleep for 10ms


proc unwatchState(watch: var WatchState) =
  if watch != nil:
    discard close(watch.fd)
    watch = nil

proc watch*(
    rootDir: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags] = {},
    userData: pointer = nil,
): WatchId =
  ## Create Dmon watch using inotify events
  let watch = dmon.watchInit(rootdir, watchCb, flags, userData)

  withLock dmon.threadLock:
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
    if Recursive in flags:
      watch.watchRecursive(
        watch.rootDir, watch.fd, inotifyMask.cuint, FollowSymlinks in flags
      )

    result = WatchId(watch.id)
    notice "watchDmon: done"

proc initDmonImpl*() =
  discard

proc unwatchState(watch: WatchState) =
  if watch != nil:
    discard close(watch.fd)

proc unwatchState*(id: WatchId) =

  let index = int(id) - 1
  assert index < 64
  assert dmon.watches[index] != nil
  assert dmon.numWatches > 0

  if dmon.watches[index] != nil:
    withLock dmon.threadLock:
      dmon.watches[index] = nil

      dec dmon.numWatches
      let numFreeList = 64 - dmon.numWatches
      dmon.freeList[numFreeList - 1] = index
