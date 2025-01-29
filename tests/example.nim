import std/os
import dmon
import dmon/logging

proc main() =
  let cb: WatchCallback = proc(
      watchId: WatchId,
      action: DmonAction,
      rootDir, filepath, oldfilepath: string,
      userData: pointer,
  ) {.gcsafe.} =
    echo "callback: ", "watchId: ", watchId.repr
    echo "callback: ", "action: ", action.repr
    echo "callback: ", "rootDir: ", rootDir.repr
    echo "callback: ", "file: ", filepath.repr
    echo "callback: ", "old: ", oldfilepath.repr

  initDmon()
  startDmonThread()

  echo("waiting for changes ..")
  let args = commandLineParams()
  let root = 
    if args.len() == 0:
      "./tests/"
    else:
      args[0]
  let watchId: WatchId = watch( root, cb, {Recursive}, nil)
  echo "watchId:repr: ", watchId.repr
  # let watchId2: WatchId = watch("src/", cb, {Recursive}, nil)
  # discard watchDmon("/tmp/testmon/", cb, {Recursive}, nil)
  os.sleep(30_000)
  watchId.unwatch()
  echo("done ..")
  deinitDmon()

main()
