import std/[assertions, locks, monotimes, os, sets, tempfiles, times]

import dmon

var
  eventLock: Lock
  expectedWatch: WatchId
  reported: bool

proc callback(
    watchId: WatchId,
    action: DmonAction,
    rootDir, filepath, oldfilepath: string,
    userData: pointer,
) =
  withLock(eventLock):
    if uint32(watchId) == uint32(expectedWatch) and filepath == "probe.txt":
      reported = true

proc waitForEvent(): bool =
  let deadline = getMonoTime() + initDuration(seconds = 60)
  while getMonoTime() < deadline:
    withLock(eventLock):
      if reported:
        return true
    sleep(10)

when defined(macosx) and not defined(bsdTest):
  proc waitForStarted(watchId: WatchId): bool =
    let deadline = getMonoTime() + initDuration(seconds = 60)
    while getMonoTime() < deadline:
      withLock(dmonInst.threadLock):
        let index = int(uint32(watchId)) - 1
        if dmonInst.watches[index].init:
          return dmonInst.watches[index].started
      sleep(10)

block configuredWatchCapacity:
  let root = createTempDir("dmon-capacity-", "")
  initLock(eventLock)
  initDmon()
  startDmonThread()
  var watches: seq[WatchId]
  var unreleasedSlots: int
  try:
    doAssert dmonInst.watches.len == dmonMaxWatches
    doAssert dmonInst.freeList.len == dmonMaxWatches
    var ids: HashSet[uint32]
    for index in 0 ..< dmonMaxWatches:
      let directory = root / $index
      createDir(directory)
      let id = watch(directory, callback, {}, nil)
      watches.add(id)
      doAssert uint32(id) > 0,
        "native registration failed before configured capacity (check OS quotas)"
      doAssert uint32(id) <= uint32(dmonMaxWatches)
      doAssert uint32(id) notin ids, "live watches must have unique IDs"
      ids.incl(uint32(id))
    doAssert dmonInst.numWatches == dmonMaxWatches
    doAssertRaises ValueError:
      discard watch(root, callback, {}, nil)
    doAssert dmonInst.numWatches == dmonMaxWatches,
      "exhausting capacity must not consume another slot"

    let releasedIndex = dmonMaxWatches div 2
    let releasedId = watches[releasedIndex]
    releasedId.unwatch()
    watches[releasedIndex] = WatchId(0)
    doAssert dmonInst.numWatches == dmonMaxWatches - 1
    let replacement = watch(root / $releasedIndex, callback, {}, nil)
    watches[releasedIndex] = replacement
    doAssert uint32(replacement) == uint32(releasedId),
      "a released slot should be reused even at the capacity limit"
    doAssert dmonInst.numWatches == dmonMaxWatches

    let lastWatch = watches[^1]
    withLock(eventLock):
      expectedWatch = lastWatch
    when defined(macosx) and not defined(bsdTest):
      doAssert waitForStarted(lastWatch), "last FSEvents stream should start"
    elif defined(bsdTest) or defined(bsd):
      let deadline = getMonoTime() + initDuration(seconds = 60)
      var ready: bool
      while not ready and getMonoTime() < deadline:
        withLock(dmonInst.threadLock):
          ready = dmonInst.watches[int(uint32(lastWatch)) - 1].ready
        sleep(10)
      doAssert ready, "last BSD watch should take its initial snapshot"
    writeFile(root / $(dmonMaxWatches - 1) / "probe.txt", "probe")
    doAssert waitForEvent(), "the last configured slot should deliver events"
  finally:
    for id in watches:
      if uint32(id) > 0:
        id.unwatch()
    unreleasedSlots = dmonInst.numWatches
    deinitDmon()
    deinitLock(eventLock)
    removeDir(root)
  doAssert unreleasedSlots == 0, "all watch slots should be released"
