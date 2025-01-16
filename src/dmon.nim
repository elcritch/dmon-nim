
when defined(macosx):
  import dmon/macos
  export macos

type
  DmonWatchId* = distinct uint32

  DmonWatchFlags* = enum
    Recursive = 0x1
    FollowSymlinks = 0x2
    OutOfScopeLinks = 0x4
    IgnoreDirectories = 0x8

  DmonAction* = enum
    Create = 1
    Delete
    Modify
    Move

  DmonWatchCallback* = proc(
    watchId: DmonWatchId,
    action: DmonAction,
    rootdir, filepath, oldfilepath: string,
    userData: pointer,
  )

  DmonFsEvent = ref object
    filepath: string
    eventId: FSEventStreamEventId
    eventFlags: set[FSEventStreamEventFlag]
    watchId: DmonWatchId
    skip: bool
    moveValid: bool

  DmonWatchState = ref object
    id: DmonWatchId
    watchFlags: set[DmonWatchFlags]
    fsEvStreamRef: FSEventStreamRef
    watchCb: DmonWatchCallback
    userData: pointer
    rootdir: string
    rootdirUnmod: string
    init: bool

  DmonState = object
    watches: array[64, DmonWatchState]
    freeList: array[64, int]
    events: seq[DmonFsEvent]
    numWatches: int
    # modifyWatches: Atomic[int]
    threadHandle: Thread[void]
    threadLock: Lock
    threadSem: Cond
    cfLoopRef: CFRunLoopRef
    cfAllocRef: CFAllocatorRef
    quit: bool

var
  dmonInitialized: bool
  dmon: DmonState

iterator watchStates(dmon: DmonState): DmonWatchState =
  for i in 0 ..< dmon.numWatches:
    yield dmon.watches[i]
