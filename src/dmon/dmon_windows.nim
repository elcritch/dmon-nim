import std/[strutils, locks]
import std/private/globs
import std/monotimes
import std/times

import winim/lean
import winim/core
import winim/winstr

import logging
import dmontypes

# $ nim --os:windows --cpu:amd64 --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc -d:release c hello.nim

proc refreshWatch(watch: WatchState, buffer: var seq[byte]): bool =
  let recursive = watch.watchFlags.contains(Recursive)
  let res = ReadDirectoryChangesW(
    watch.dirHandle,
    buffer[0].addr,
    DWORD(buffer.len),
    WINBOOL(recursive),
    watch.notifyFilter,
    nil,
    watch.overlapped.addr,
    nil
  )
  trace "refreshWatch", readDirChanges = res
  return res != 0

proc unwatchState*(watch: var WatchState) =
  CancelIo(watch.dirHandle)
  CloseHandle(watch.overlapped.hEvent)
  CloseHandle(watch.dirHandle)

proc processEvents(events: seq[FileEvent]) =
  debug "processEvents:", events = events.repr
  for i in 0 ..< events.len:
    var ev = events[i].addr
    if ev.skip:
      debug "processEvents:skip: ", ev = ev.repr
      continue

    if ev.action == FILE_ACTION_MODIFIED or ev.action == FILE_ACTION_ADDED:
      # Coalesce multiple modifications
      for j in (i + 1) ..< events.len:
        let checkEv = events[j].addr
        if checkEv.action == FILE_ACTION_MODIFIED and
            ev.filepath == checkEv.filePath:
          checkEv.skip = true

  # Process events
  for i in 0 ..< events.len:
    let ev = events[i].addr
    if ev.skip:
      debug "processEvents:skip: ", ev = ev.repr
      continue

    let watch = dmonInst.watches[ev.watchId.uint32 - 1]
    if watch.isNil or watch.watchCb.isNil:
      debug "processEvents:skip: watch nil: ", ev = ev.repr
      continue

    debug "processEvents:event: ", ev = ev.repr
    case ev.action
    of FILE_ACTION_ADDED:
      watch.watchCb(
        ev.watchId,
        Create,
        watch.rootdir,
        ev.filepath,
        "",
        watch.userData
      )
    of FILE_ACTION_MODIFIED:
      watch.watchCb(
        ev.watchId,
        DmonAction.Modify,
        watch.rootdir,
        ev.filepath,
        "",
        watch.userData
      )
    of FILE_ACTION_RENAMED_OLD_NAME:
      # Find corresponding new name event
      for j in (i + 1) ..< events.len:
        let checkEv = events[j].addr
        if checkEv.action == FILE_ACTION_RENAMED_NEW_NAME:
          watch.watchCb(
            checkEv.watchId,
            DmonAction.Move,
            watch.rootdir,
            checkEv.filepath,
            ev.filepath,
            watch.userData
          )
          break
    of FILE_ACTION_REMOVED:
      watch.watchCb(
        ev.watchId,
        DmonAction.Delete,
        watch.rootdir,
        ev.filepath,
        "",
        watch.userData
      )
    else: discard


template toSlice(buff: seq): openArray[byte] =
  buff.toOpenArray(0, buff.len())

proc processWatches() =
  trace "processWatches"

  var 
    waitHandlesArr: array[64, HANDLE]
    watchStatesArr: array[64, WatchState]
    elapsed: Duration
    startTime = getMonoTime()


  #   startTime: SYSTEMTIME
  #   elapsed: uint64
  # GetSystemTime(startTime.addr)

  withLock(dmonInst.threadLock):
    trace "processWatches: watchStates", numWatches = dmonInst.numWatches
    for i in 0 ..< 64:
      if not dmonInst.watches[i].isNil:
        let watch = dmonInst.watches[i]
        watchStatesArr[i] = watch
        waitHandlesArr[i] = watch.overlapped.hEvent

    let waitResult = WaitForMultipleObjects(
      DWORD(dmonInst.numWatches),
      waitHandlesArr[0].addr,
      FALSE,
      10
    )
    trace "processWatches: watchStates", waitResult = waitResult.repr, waitTimeout = WAIT_TIMEOUT

    if waitResult != WAIT_TIMEOUT:
      # var fileInfobufferSeq = newSeq[byte](64512)
      var fileInfobufferSeq = newSeq[byte](32768)
      let watch = watchStatesArr[waitResult - WAIT_OBJECT_0]
      var bytes: DWORD = 0
      let res = GetOverlappedResult(watch.dirHandle, watch.overlapped.addr, bytes.addr, FALSE)
      if res != 0:
        trace "processWatches:GetOverlappedResult", overlapRes = res, watch = watch.repr
        var 
          offset: int

        if bytes == 0:
          debug "processWatches:refreshWatch:", watch = watch.repr
          discard refreshWatch(watch, fileInfobufferSeq)
          return

        while true:
          debug "processWatches:watch:process: ", offset = offset, bytes = bytes, watch = watch.repr
          let notify = cast[ptr FILE_NOTIFY_INFORMATION](fileInfobufferSeq[0].addr)
          debug "processWatches:watch:notify: ", notify = notify.repr
          debug "processWatches:watch:notify:seq: ", notify = fileInfobufferSeq[0..300].repr

          let filepath = $(cast[ptr WCHAR](notify.FileName))
          let unixPath = nativeToUnixPath(filepath)
          trace "processWatches: converted filename", filepath = filepath, unixPath = unixPath, fileNameWin = notify.FileName
          
          if dmonInst.events.len == 0:
            elapsed = initDuration(seconds=0)

          var wev = FileEvent(
            action: notify.Action,
            watchId: watch.id,
            filepath: unixPath,
            skip: false
          )
          dmonInst.events.add(wev)

          if notify.NextEntryOffset == 0:
            break
          offset += int(notify.NextEntryOffset)

        # TODO: what's this bit about?
        # if not dmonInst.quit:
        #   discard refreshWatch(watch)

    var currentTime = getMonoTime()
    
    startTime = currentTime
    elapsed = currentTime - startTime

    if elapsed.inMicroseconds > 100 and dmonInst.events.len > 0:
      if dmonInst.events.len() > 0:
        processEvents(move dmonInst.events)
      assert dmonInst.events.len() == 0
      elapsed = initDuration(seconds=0)

proc monitorThread*() {.thread.} =
  {.cast(gcsafe).}:
    notice "starting thread"
    
    threadExec()

proc initDmonImpl*() =
  info "initDmonImpl "

proc watch*(
    rootDirectory: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags] = {},
    userData: pointer = nil,
): WatchId =

  withLock dmonInst.threadLock:
    var watch = watchInit(rootDirectory, watchCb, flags, userData)
    
    let rootWS: LPCSTR = watch.rootDir
    watch.dirHandle = CreateFileA(
      rootWS,
      GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED,
      0.HANDLE
    )

    if watch.dirHandle != INVALID_HANDLE_VALUE:
      watch.notifyFilter = FILE_NOTIFY_CHANGE_CREATION or
                          FILE_NOTIFY_CHANGE_LAST_WRITE or
                          FILE_NOTIFY_CHANGE_FILE_NAME or 
                          FILE_NOTIFY_CHANGE_DIR_NAME or
                          FILE_NOTIFY_CHANGE_SIZE

      watch.overlapped.hEvent = CreateEvent(nil, TRUE, FALSE, nil)
      assert(watch.overlapped.hEvent != INVALID_HANDLE_VALUE)

      var fileInfobufferSeq = newSeq[byte](64512)
      if not refreshWatch(watch, fileInfobufferSeq):
        unwatchState(watch)
        error "ReadDirectoryChanges failed"
        # release(dmonInst.mutex)
        # discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
        return WatchId(0)
    else:
      warn "Could not open: ", rootDir = watch.rootDir
      # release(dmonInst.mutex)
      # discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
      return WatchId(0)

    # release(dmonInst.mutex)
    # discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
    return WatchId(watch.id)
