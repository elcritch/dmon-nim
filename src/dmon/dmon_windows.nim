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

proc refreshWatch(watch: WatchState, buffer: openArray[byte]): bool =
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
  return res != 0

proc unwatchState*(watch: WatchState) =
  CancelIo(watch.dirHandle)
  CloseHandle(watch.overlapped.hEvent)
  CloseHandle(watch.dirHandle)

proc processEvents() =
  for i in 0 ..< dmonInst.events.len:
    var ev = dmonInst.events[i].addr
    if ev.skip:
      continue

    if ev.action == FILE_ACTION_MODIFIED or ev.action == FILE_ACTION_ADDED:
      # Coalesce multiple modifications
      for j in (i + 1) ..< dmonInst.events.len:
        let checkEv = dmonInst.events[j].addr
        if checkEv.action == FILE_ACTION_MODIFIED and
            ev.filepath == checkEv.filePath:
          checkEv.skip = true

  # Process events
  for i in 0 ..< dmonInst.events.len:
    let ev = dmonInst.events[i].addr
    if ev.skip:
      continue

    let watch = dmonInst.watches[ev.watchId.uint32 - 1]
    if watch.isNil or watch.watchCb.isNil:
      continue

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
      for j in (i + 1) ..< dmonInst.events.len:
        let checkEv = dmonInst.events[j].addr
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

  dmonInst.events.setLen(0)

template toSlice(buff: seq): openArray[byte] =
  buff.toOpenArray(0, buff.len())

proc processWatches() =

  var 
    waitHandles: array[64, HANDLE]
    watchStates: array[64, WatchState]
    elapsed: Duration
    startTime = getMonoTime()


  #   startTime: SYSTEMTIME
  #   elapsed: uint64
  # GetSystemTime(startTime.addr)

  withLock(dmonInst.threadLock):
    for i in 0 ..< 64:
      if not dmonInst.watches[i].isNil:
        let watch = dmonInst.watches[i]
        watchStates[i] = watch
        waitHandles[i] = watch.overlapped.hEvent

    let waitResult = WaitForMultipleObjects(
      DWORD(dmonInst.numWatches),
      waitHandles[0].addr,
      FALSE,
      10
    )

    if waitResult != WAIT_TIMEOUT:
      var fileInfobufferSeq = newSeq[byte](64512)
      let watch = watchStates[waitResult - WAIT_OBJECT_0]
      var bytes: DWORD = 0
      if GetOverlappedResult(watch.dirHandle, watch.overlapped.addr, bytes.addr, FALSE) != 0:
        var 
          offset: int

        if bytes == 0:
          discard refreshWatch(watch, fileInfobufferSeq.toSlice())
          return

        while true:
          let notify = cast[ptr FILE_NOTIFY_INFORMATION](fileInfobufferSeq[0].addr)

          let filepath = $(cast[ptr WCHAR](notify.FileName))
          let unixPath = nativeToUnixPath(filepath)
          trace "processWatches: converted filename", filepath = filepath, unixPath = unixPath
          
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
      processEvents()
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
    let watch = watchInit(rootDirectory, watchCb, flags, userData)
    
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
      if not refreshWatch(watch, fileInfobufferSeq.toSlice()):
        unwatchState(watch)
        error "ReadDirectoryChanges failed"
        # release(dmonInst.mutex)
        # discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
        return DmonWatchId(0)
    else:
      warning "Could not open: ", rootDir = watch.rootDir
      # release(dmonInst.mutex)
      # discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
      return DmonWatchId(0)

    # release(dmonInst.mutex)
    # discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
    return DmonWatchId(id)

proc dmonUnwatch*(id: DmonWatchId) =
  assert(dmonInit)
  assert(uint32(id) > 0)
  
  let index = uint32(id) - 1
  assert(index < 64)
  assert(not dmonInst.watches[index].isNil)
  assert(dmonInst.numWatches > 0)

  if not dmonInst.watches[index].isNil:
    discard interlockedExchange(dmonInst.modifyWatches.addr, 1)
    acquire(dmonInst.mutex)

    unwatchState(dmonInst.watches[index])
    dealloc(dmonInst.watches[index])
    dmonInst.watches[index] = nil

    dec dmonInst.numWatches
    let numFreelist = 64 - dmonInst.numWatches
    dmonInst.freelist[numFreelist - 1] = int32(index)

    release(dmonInst.mutex)
    discard interlockedExchange(dmonInst.modifyWatches.addr, 0)