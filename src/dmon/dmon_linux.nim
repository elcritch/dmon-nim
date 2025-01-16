import std/posix
import std/[os, strutils, paths]
import std/locks
import std/inotify
# import std/times
from std/times import getTime, Time

import logging
import dmontypes

const LINUX_PATH_MAX = 4096
let path_max_sys {.importc, extern: "PATH_MAX", header: "#include <linux/limits.h>".}: cint

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
    trace "findSubDir", watchWd = watchWd, wd = wd
    if wd == watchWd:
      trace "findSubDir: found", rootDir = watch.subdirs[i].rootDir
      return watch.subdirs[i].rootDir
  return ""

# Process inotify events
proc processEvents(events: seq[FileEvent]) =
  trace "processing processEvents ", eventsLen = events.len()
  for i, ev in events:
    trace "processWatches: ev", ev = ev.repr
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

    let watch = dmonInst.watches[uint32(ev.watchId) - 1]
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
      for j in (i+1)..<dmonInst.events.len:
        let checkEv = addr dmonInst.events[j]
        if (checkEv.mask and IN_MOVED_TO) != 0 and ev.cookie == checkEv.cookie:
          watch.watchCb(checkEv.watchId, Move, watch.rootDir,
                       checkEv.filePath, ev.filePath, watch.userData)
          break

    elif (ev.mask and IN_DELETE) != 0:
      watch.watchCb(ev.watchId, Delete, watch.rootDir, ev.filePath, "", watch.userData)

  dmonInst.events.setLen(0)

# const BufferSize = sizeof(FileEvent) * 1024
const MaxWatches = 8192

proc processWatches() =
  debug "monitor: processWatches "

  # setup watches / readfds
  # var buffer: array[1024, (InotifyEvent, array[LINUX_PATH_MAX, char])]
  var readfds: TFdSet
  FD_ZERO(readfds)
  
  # Add all watch file descriptors to the set
  for i in 0..<dmonInst.numWatches:
    let watch = dmonInst.watches[i]
    if watch != nil:
      FD_SET(watch.fd.cint, readfds)

  var timeout: Timeval
  timeout.tv_sec = posix.Time(0)
  timeout.tv_usec = Suseconds(500_000) # 100ms timeout

  if select(FD_SETSIZE, addr readfds, nil, nil, addr timeout) <= 0:
    return

  trace "monitor: select readfds "
  for watch in dmonInst.watchStates():
    trace "process watch ", watch = watch.repr
    assert watch != nil
    if FD_ISSET(watch.fd.cint, readfds) != 0:
      trace "inotify isset: ", watchFd = watch.fd

      var events: array[MaxWatches, byte]  # event buffer
      while true:
        let n = read(watch.fd, addr events, MaxWatches)
        if n <= 0:
          trace "processWatches: inotify events: ", watchFd = watch.fd
          break
        # blocks until any events have been read
        for iev in inotify_events(addr events, n):
          let watchId = iev[].wd
          let mask = iev[].mask
          let name = $cast[cstring](addr iev[].name)    # echo watch id, mask, and name value of each event
          let subdir = watch.findSubdir(watchId)
          trace "processWatches: inotify events: post",
            watchId = watchId, mask = mask, name = name, subdir = subdir

          if subdir.len > 0:
            let filepath = subdir / name

            var event = FileEvent(
              filePath: filepath,
              mask: iev.mask,
              cookie: iev.cookie,
              watchId: watch.id,
              skip: false
            )
            dmonInst.events.add(event)
        trace "processWatches: finished inotify events", watchFd = watch.fd
        processEvents(move dmonInst.events)
        assert dmonInst.events.len() == 0

  # Check elapsed time and process events if needed
  # let currentTime = getTime()
  # let dt = (currentTime - startTime).inMicroseconds
  # startTime = currentTime
  # microSecsElapsed += dt
  
  # if microSecsElapsed > 100_000 and dmonInst.events.len > 0:
  # microSecsElapsed = 0

proc monitorThread*() {.thread.} =
  {.cast(gcsafe).}:
    notice "starting thread"
    
    threadExec()

proc unwatchState*(watch: var WatchState) =
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
  let watch = watchInit(rootdir, watchCb, flags, userData)

  withLock dmonInst.threadLock:
    # Initialize inotify
    watch.fd = inotify_init()
    info "inotify init", watchFd = watch.fd
    if watch.fd.cint < 0:
      return WatchId(0)

    let inotifyMask =
      IN_MOVED_TO or IN_CREATE or IN_MOVED_FROM or IN_DELETE or IN_MODIFY
    let wd = inotify_add_watch(watch.fd.cint, watch.rootDir.cstring, inotifyMask.cuint)

    if wd < 0:
      return WatchId(0)

    watch.subdirs.add WatchSubdir(rootDir: watch.rootDir)
    watch.wds.add wd

    # Handle recursive watching if requested
    if Recursive in flags:
      watch.watchRecursive(
        watch.rootDir, watch.fd, inotifyMask.cuint, FollowSymlinks in flags
      )

    result = WatchId(watch.id)
    notice "watchDmon: done"

proc initDmonImpl*() =
  info "initDmonImpl: ", path_max_sys = path_max_sys
  assert path_max_sys == LINUX_PATH_MAX
  discard
