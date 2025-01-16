
import posix
import std/[os, strutils, paths]
import std/locks
import std/inotify

import logging
import dmontypes

type
  WatchSubdir = object
    rootDir: string

  WatchState = ref object
    id: WatchId
    watchFlags: set[WatchFlags]
    watchCb: WatchCallback

    fd: FileHandle
    userData: pointer
    rootDir: string
    subdirs: seq[WatchSubdir]
    wds: seq[cint]

  DmonState = object
    watches: array[64, WatchState]
    freeList: array[64, int]
    events: seq[InotifyEvent]
    numWatches: int
    thread: Thread[void]
    mutex: Lock
    quit: bool

var 
  dmonInitialized = false
  dmon: DmonState

const MaxPath = 260

proc watchRecursive(dirname: string, fd: FileHandle, mask: uint32,
                   followLinks: bool, watch: WatchState) =
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
      if not watchDir.endsWith("/"): watchDir.add '/'
      
      let wd = inotify_add_watch(fd.cint, watchDir.cstring, mask.cuint)
      assert wd != -1, "Failed to add watch for " & watchDir
      
      var subdir = WatchSubdir(rootDir: watchDir)
      if subdir.rootDir.startsWith(watch.rootDir):
        subdir.rootDir = subdir.rootDir[watch.rootDir.len..^1]
        
      watch.subdirs.add subdir
      watch.wds.add wd
      
      watchRecursive(watchDir, fd, mask, followLinks, watch)

proc findSubdir(watch: WatchState, wd: cint): string =
  for i, watchWd in watch.wds:
    if wd == watchWd:
      return watch.subdirs[i].rootDir
  return ""

# Main initialization
proc init*() =
  assert not dmonInitialized
  initLock(dmon.mutex)
  
  # Initialize freeList array
  for i in 0..<64:
    dmon.freeList[i] = 63 - i
    
  dmonInitialized = true

# Main deinitialization
proc deinit*() =
  assert dmonInitialized
  dmon.quit = true
  joinThread(dmon.thread)
  
  for i in 0..<dmon.numWatches:
    if dmon.watches[i] != nil:
      discard close(dmon.watches[i].fd)
      dmon.watches[i] = nil
      
  dmon.events.setLen(0)
  dmon.mutex.deinitLock()
  dmonInitialized = false

# Main watch function
proc watch*(rootDir: string, callback: WatchCallback, 
           flags: set[WatchFlags] = {}, userData: pointer = nil): WatchId =
  assert dmonInitialized
  assert callback != nil
  assert rootDir.len > 0
  
  withLock dmon.mutex:
    assert dmon.numWatches < 64, "Exceeding maximum number of watches"
    
    let numFreeList = 64 - dmon.numWatches
    let index = dmon.freeList[numFreeList - 1]
    let id = WatchId(index + 1)
    
    if dmon.watches[index] == nil:
      dmon.watches[index] = WatchState()
    
    inc dmon.numWatches
    
    let watch = dmon.watches[index]
    watch.id = id
    watch.watchFlags = flags
    watch.watchCb = callback
    watch.userData = userData
    
    # Verify directory exists and is readable
    try:
      # let info = getFileInfo(rootDir)
      if not rootDir.dirExists(): # or not os.fileAccessible(rootDir, {fpUserRead}):
        raise newException(OSError, "Could not open/read directory: " & rootDir)
        
      if info.kind == pcLinkToDir:
        if wfFollowSymlinks in flags:
          watch.rootDir = expandSymlink(rootDir)
        else:
          raise newException(OSError, "Symlinks unsupported without wfFollowSymlinks flag")
      else:
        watch.rootDir = rootDir
        
    except OSError as e:
      return WatchId(0)
    
    # Ensure rootDir ends with /
    if not watch.rootDir.endsWith("/"): 
      watch.rootDir.add '/'
      
    # Initialize inotify
    watch.fd = inotify_init().FileHandle
    if watch.fd.cint < 0:
      return WatchId(0)
      
    let inotifyMask = IN_MOVED_TO or IN_CREATE or IN_MOVED_FROM or IN_DELETE or IN_MODIFY
    let wd = inotify_add_watch(watch.fd.cint, watch.rootDir.cstring, inotifyMask.cuint) 
    
    if wd < 0:
      return WatchId(0)
      
    watch.subdirs.add WatchSubdir(rootDir: "")
    watch.wds.add wd
    
    # Handle recursive watching if requested
    if wfRecursive in flags:
      watchRecursive(watch.rootDir, watch.fd, inotifyMask.cuint,
                    wfFollowSymlinks in flags, watch)
                    
    return id

# Unwatch a directory
proc unwatch*(id: WatchId) =
  assert dmonInitialized
  assert uint32(id) > 0
  
  let index = int(id) - 1
  assert index < 64
  assert dmon.watches[index] != nil
  assert dmon.numWatches > 0
  
  if dmon.watches[index] != nil:
    withLock dmon.mutex:
      discard close(dmon.watches[index].fd)
      dmon.watches[index] = nil
      
      dec dmon.numWatches
      let numFreeList = 64 - dmon.numWatches  
      dmon.freeList[numFreeList - 1] = index