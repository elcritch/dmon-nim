import std/[strutils, locks]

import winim/lean

import dmontypes

# $ nim --os:windows --cpu:amd64 --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc -d:release c hello.nim

proc refreshWatch(watch: var WatchState): bool =
  let recursive = watch.watchFlags.contains(Recursive)
  let res = ReadDirectoryChangesW(
    watch.dirHandle,
    watch.buffer[0].addr,
    DWORD(watch.buffer.len),
    WINBOOL(recursive),
    watch.notifyFilter,
    nil,
    watch.overlapped.addr,
    nil
  )
  assert res != 0

proc unwatchInternal(watch: WatchState) =
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

proc dmonThread(arg: pointer): DWORD {.stdcall.} =
  var 
    waitHandles: array[64, HANDLE]
    watchStates: array[64, WatchState]
    startTime: SYSTEMTIME
    msecsElapsed: uint64

  GetSystemTime(startTime.addr)

  while not dmonInst.quit:
    if dmonInst.modifyWatches != 0 or not tryAcquire(dmonInst.mutex):
      Sleep(10)
      continue

    if dmonInst.numWatches == 0:
      Sleep(10)
      release(dmonInst.mutex)
      continue

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
      let watch = watchStates[waitResult - WAIT_OBJECT_0]
      var bytes: DWORD
      if GetOverlappedResult(watch.dirHandle, watch.overlapped.addr, bytes.addr, FALSE) != 0:
        var 
          filepath: array[260, WCHAR]
          notify: ptr FILE_NOTIFY_INFORMATION
          offset: int

        if bytes == 0:
          discard refreshWatch(watch)
          release(dmonInst.mutex)
          continue

        while true:
          notify = cast[ptr FILE_NOTIFY_INFORMATION](watch.buffer[offset].addr)
          
          let count = WideCharToMultiByte(
            CP_UTF8,
            0,
            notify.FileName.addr,
            int32(notify.FileNameLength div sizeof(WCHAR)),
            filepath[0].addr,
            259,
            nil,
            nil
          )
          filepath[count] = 0.WCHAR

          let unixPath = toUnixPath($filepath)
          
          if dmonInst.events.len == 0:
            msecsElapsed = 0

          var wev = DmonWin32Event(
            action: notify.Action,
            watchId: watch.id,
            skip: false
          )
          copyMem(wev.filepath[0].addr, unixPath[0].unsafeAddr, min(unixPath.len, 259))
          wev.filepath[min(unixPath.len, 259)] = '\0'
          dmonInst.events.add(wev)

          if notify.NextEntryOffset == 0:
            break
          offset += int(notify.NextEntryOffset)

        if not dmonInst.quit:
          discard refreshWatch(watch)

    var currentTime: SYSTEMTIME
    GetSystemTime(currentTime.addr)
    
    let dt = (currentTime.wSecond - startTime.wSecond) * 1000 +
             (currentTime.wMilliseconds - startTime.wMilliseconds)
    startTime = currentTime
    msecsElapsed += uint64(dt)

    if msecsElapsed > 100 and dmonInst.events.len > 0:
      processEvents()
      msecsElapsed = 0

    release(dmonInst.mutex)

  result = 0

proc dmonInit*() =
  assert(not dmonInit)
  initLock(dmonInst.mutex)

  dmonInst.threadHandle = createThread(nil, 0, dmonThread, nil, 0, nil)
  assert(not dmonInst.threadHandle.isNil)

  for i in 0 ..< 64:
    dmonInst.freelist[i] = 64 - i - 1

  dmonInit = true

proc dmonDeinit*() =
  assert(dmonInit)
  dmonInst.quit = true
  
  if dmonInst.threadHandle != INVALID_HANDLE_VALUE:
    discard WaitForSingleObject(dmonInst.threadHandle, INFINITE)
    CloseHandle(dmonInst.threadHandle)

  for i in 0 ..< 64:
    if not dmonInst.watches[i].isNil:
      unwatchInternal(dmonInst.watches[i])
      dealloc(dmonInst.watches[i])

  deinitLock(dmonInst.mutex)
  dmonInst.events = @[]
  reset(dmon)
  dmonInit = false

proc dmonWatch*(rootdir: string, watchCb: WatchCallback,
                flags: WatchFlags, userData: pointer): DmonWatchId =
  assert(dmonInit)
  assert(not watchCb.isNil)
  assert(rootdir.len > 0)

  discard interlockedExchange(dmonInst.modifyWatches.addr, 1)
  acquire(dmonInst.mutex)

  assert(dmonInst.numWatches < 64)
  if dmonInst.numWatches >= 64:
    stderr.writeLine "Exceeding maximum number of watches"
    release(dmonInst.mutex)
    discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
    return DmonWatchId(0)

  let 
    numFreelist = 64 - dmonInst.numWatches
    index = dmonInst.freelist[numFreelist - 1]
    id = uint32(index + 1)

  if dmonInst.watches[index].isNil:
    dmonInst.watches[index] = WatchState()
    if dmonInst.watches[index].isNil:
      release(dmonInst.mutex)
      discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
      return DmonWatchId(0)

  inc dmonInst.numWatches

  let watch = dmonInst.watches[index]
  watch.id = DmonWatchId(id)
  watch.watchFlags = flags
  watch.watchCb = watchCb
  watch.userData = userData

  let unixPath = toUnixPath(rootdir)
  copyMem(watch.rootdir[0].addr, unixPath[0].unsafeAddr, min(unixPath.len, 259))
  
  # Ensure path ends with /
  var pathLen = strlen(watch.rootdir[0].addr)
  if watch.rootdir[pathLen - 1] != '/':
    watch.rootdir[pathLen] = '/'
    watch.rootdir[pathLen + 1] = '\0'

  watch.dirHandle = CreateFileA(
    rootdir,
    GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,
    OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED,
    nil
  )

  if watch.dirHandle != INVALID_HANDLE_VALUE:
    watch.notifyFilter = FILE_NOTIFY_CHANGE_CREATION or
                        FILE_NOTIFY_CHANGE_LAST_WRITE or
                        FILE_NOTIFY_CHANGE_FILE_NAME or 
                        FILE_NOTIFY_CHANGE_DIR_NAME or
                        FILE_NOTIFY_CHANGE_SIZE

    watch.overlapped.hEvent = CreateEvent(nil, TRUE, FALSE, nil)
    assert(watch.overlapped.hEvent != INVALID_HANDLE_VALUE)

    if not refreshWatch(watch):
      unwatchInternal(watch)
      stderr.writeLine "ReadDirectoryChanges failed"
      release(dmonInst.mutex)
      discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
      return DmonWatchId(0)
  else:
    stderr.writeLine "Could not open: ", rootdir
    release(dmonInst.mutex)
    discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
    return DmonWatchId(0)

  release(dmonInst.mutex)
  discard interlockedExchange(dmonInst.modifyWatches.addr, 0)
  result = DmonWatchId(id)

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

    unwatchInternal(dmonInst.watches[index])
    dealloc(dmonInst.watches[index])
    dmonInst.watches[index] = nil

    dec dmonInst.numWatches
    let numFreelist = 64 - dmonInst.numWatches
    dmonInst.freelist[numFreelist - 1] = int32(index)

    release(dmonInst.mutex)
    discard interlockedExchange(dmonInst.modifyWatches.addr, 0)