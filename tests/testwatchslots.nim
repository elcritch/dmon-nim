import std/[assertions, locks, os, tempfiles]

import dmon

var
  eventLock: Lock
  secondWatchReported: bool

proc callback(
    watchId: WatchId,
    action: DmonAction,
    rootDir, filepath, oldfilepath: string,
    userData: pointer,
) =
  if filepath == "probe.txt":
    withLock(eventLock):
      secondWatchReported = true

proc waitForSecondWatch(): bool =
  for _ in 0..<30:
    withLock(eventLock):
      if secondWatchReported:
        return true
    sleep(100)

block removingEarlierWatchKeepsLaterWatchActive:
  let firstDir = createTempDir("dmon-first-watch-", "")
  let secondDir = createTempDir("dmon-second-watch-", "")
  initLock(eventLock)
  initDmon()
  startDmonThread()

  var firstWatch = WatchId(0)
  var secondWatch = WatchId(0)

  try:
    firstWatch = watch(firstDir, callback, {}, nil)
    secondWatch = watch(secondDir, callback, {}, nil)
    doAssert uint32(firstWatch) > 0, "first watch should have a valid ID"
    doAssert uint32(secondWatch) > 0, "second watch should have a valid ID"

    sleep(700)
    firstWatch.unwatch()
    firstWatch = WatchId(0)
    writeFile(secondDir / "probe.txt", "probe")

    doAssert waitForSecondWatch(),
      "removing an earlier watch must not disable a later watch"
  finally:
    if uint32(firstWatch) > 0:
      firstWatch.unwatch()
    if uint32(secondWatch) > 0:
      secondWatch.unwatch()
    deinitDmon()
    deinitLock(eventLock)
    removeDir(firstDir)
    removeDir(secondDir)
