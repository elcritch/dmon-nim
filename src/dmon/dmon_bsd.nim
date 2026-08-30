import std/[locks, os, sets, tables]

import dmontypes
import logging

func isDirectory(entry: BsdWatchEntry): bool =
  entry.kind in {pcDir, pcLinkToDir}

func sameIdentity(a, b: BsdWatchEntry): bool =
  a.deviceId == b.deviceId and a.fileId == b.fileId

func wasModified(a, b: BsdWatchEntry): bool =
  not a.isDirectory and
    (a.size != b.size or a.permissions != b.permissions or
      a.lastWriteTime != b.lastWriteTime)

proc toEntry(filepath, absolutePath: string, followSymlink: bool): BsdWatchEntry =
  let info = getFileInfo(absolutePath, followSymlink)
  result = BsdWatchEntry(
    filepath: filepath,
    deviceId: info.id.device,
    fileId: info.id.file,
    kind: info.kind,
    size: info.size,
    permissions: info.permissions,
    lastWriteTime: info.lastWriteTime,
  )

proc scanWatch(watch: WatchState): seq[BsdWatchEntry] =
  if not dirExists(watch.rootDir):
    return

  let recursive = Recursive in watch.watchFlags
  let followLinks = FollowSymlinks in watch.watchFlags
  let rootInfo = getFileInfo(watch.rootDir)
  var visited = initHashSet[tuple[device: DeviceId, file: FileId]]()
  visited.incl(rootInfo.id)

  var directories = @[""]
  while directories.len > 0:
    let relativeDir = directories.pop()
    let absoluteDir = watch.rootDir / relativeDir

    for kind, absolutePath in walkDir(absoluteDir):
      let filepath = relativeDir / absolutePath.extractFilename
      let followsLink = followLinks and kind in {pcLinkToFile, pcLinkToDir}

      try:
        let entry = toEntry(filepath, absolutePath, followsLink)
        result.add(entry)

        if recursive and
            (kind == pcDir or (kind == pcLinkToDir and followLinks)):
          let identity = (entry.deviceId, entry.fileId)
          if identity notin visited:
            visited.incl(identity)
            directories.add(filepath)
      except OSError:
        discard

proc shouldReport(watch: WatchState, entry: BsdWatchEntry): bool =
  not (IgnoreDirectories in watch.watchFlags and entry.isDirectory)

proc report(
    watch: WatchState,
    action: DmonAction,
    filepath: string,
    oldfilepath = "",
) =
  if watch.watchCb != nil:
    watch.watchCb(
      watch.id, action, watch.rootDir, filepath, oldfilepath, watch.userData
    )

proc processWatch(watch: WatchState) =
  let current = scanWatch(watch)
  var oldMatched = newSeq[bool](watch.entries.len)
  var currentMatched = newSeq[bool](current.len)
  var currentByPath = initTable[string, int]()
  var currentByIdentity = initTable[
    tuple[device: DeviceId, file: FileId],
    seq[int],
  ]()

  for currentIndex, currentEntry in current:
    currentByPath[currentEntry.filepath] = currentIndex
    let identity = (currentEntry.deviceId, currentEntry.fileId)
    currentByIdentity.mgetOrPut(identity, @[]).add(currentIndex)

  for oldIndex, oldEntry in watch.entries:
    if oldEntry.filepath in currentByPath:
      let currentIndex = currentByPath[oldEntry.filepath]
      let currentEntry = current[currentIndex]
      oldMatched[oldIndex] = true
      currentMatched[currentIndex] = true

      if oldEntry.sameIdentity(currentEntry):
        if oldEntry.wasModified(currentEntry) and
            watch.shouldReport(currentEntry):
          watch.report(Modify, currentEntry.filepath)
      else:
        if watch.shouldReport(oldEntry):
          watch.report(Delete, oldEntry.filepath)
        if watch.shouldReport(currentEntry):
          watch.report(Create, currentEntry.filepath)

  for oldIndex, oldEntry in watch.entries:
    if not oldMatched[oldIndex]:
      let identity = (oldEntry.deviceId, oldEntry.fileId)
      for currentIndex in currentByIdentity.getOrDefault(identity):
        if not currentMatched[currentIndex]:
          oldMatched[oldIndex] = true
          currentMatched[currentIndex] = true
          let currentEntry = current[currentIndex]
          if watch.shouldReport(currentEntry):
            watch.report(Move, currentEntry.filepath, oldEntry.filepath)
          break

  for oldIndex, oldEntry in watch.entries:
    if not oldMatched[oldIndex] and watch.shouldReport(oldEntry):
      watch.report(Delete, oldEntry.filepath)

  for currentIndex, currentEntry in current:
    if not currentMatched[currentIndex] and watch.shouldReport(currentEntry):
      watch.report(Create, currentEntry.filepath)

  watch.entries = current

proc processWatches() =
  var watches: seq[WatchState]
  withLock(dmonInst.threadLock):
    for watch in dmonInst.watches:
      if watch != nil and watch.ready:
        watches.add(watch)

  for watch in watches:
    watch.processWatch()

proc monitorThread*() {.thread.} =
  {.cast(gcsafe).}:
    threadExec()

proc unwatchState*(watch: var WatchState) =
  watch.ready = false
  watch = nil

proc watch*(
    rootDir: string,
    watchCb: WatchCallback,
    flags: set[WatchFlags] = {},
    userData: pointer = nil,
): WatchId =
  let watch = watchInit(rootDir, watchCb, flags, userData)
  watch.entries = scanWatch(watch)
  withLock(dmonInst.threadLock):
    watch.ready = true
  result = watch.id

proc initDmonImpl*() =
  discard
