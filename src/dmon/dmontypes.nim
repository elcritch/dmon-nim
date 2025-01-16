
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

