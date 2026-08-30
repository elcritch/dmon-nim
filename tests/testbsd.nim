when defined(bsdTest) or defined(freebsd) or defined(openbsd) or
    defined(netbsd) or defined(dragonfly):
  import std/[assertions, locks, os, tempfiles]

  import dmon

  type
    ObservedEvent = tuple[
      action: DmonAction,
      filepath: string,
      oldfilepath: string,
    ]

  var
    eventLock: Lock
    observedEvents: seq[ObservedEvent]

  proc callback(
      watchId: WatchId,
      action: DmonAction,
      rootDir, filepath, oldfilepath: string,
      userData: pointer,
  ) =
    withLock(eventLock):
      observedEvents.add((action, filepath, oldfilepath))

  proc observed(
      action: DmonAction,
      filepath: string,
      oldfilepath = "",
  ): bool =
    withLock(eventLock):
      result = (action, filepath, oldfilepath) in observedEvents

  proc waitForEvent(
      action: DmonAction,
      filepath: string,
      oldfilepath = "",
  ): bool =
    for _ in 0..<30:
      if observed(action, filepath, oldfilepath):
        return true
      sleep(100)

  block bsdBackendReportsFileChanges:
    let testDir = createTempDir("dmon-bsd-test-", "")
    initLock(eventLock)
    initDmon()
    startDmonThread()
    var watchId = WatchId(0)

    try:
      watchId = watch(testDir, callback, {Recursive})
      doAssert uint32(watchId) > 0, "watch should return a valid ID"

      let originalPath = testDir / "original.txt"
      writeFile(originalPath, "one")
      doAssert waitForEvent(Create, "original.txt"),
        "create event was not reported"

      writeFile(originalPath, "a longer value")
      doAssert waitForEvent(Modify, "original.txt"),
        "modify event was not reported"

      let renamedPath = testDir / "renamed.txt"
      moveFile(originalPath, renamedPath)
      doAssert waitForEvent(Move, "renamed.txt", "original.txt"),
        "move event was not reported"

      let nestedDir = testDir / "nested"
      createDir(nestedDir)
      writeFile(nestedDir / "child.txt", "nested")
      doAssert waitForEvent(Create, "nested/child.txt"),
        "recursive create event was not reported"

      removeFile(renamedPath)
      doAssert waitForEvent(Delete, "renamed.txt"),
        "delete event was not reported"

    finally:
      if uint32(watchId) > 0:
        watchId.unwatch()
      deinitDmon()
      deinitLock(eventLock)
      removeDir(testDir)
