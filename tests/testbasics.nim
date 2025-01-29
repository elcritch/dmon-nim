# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest

import std/[times, os, strformat, strutils]

import dmon
import dmon/logging

var
  eventFileModified = ""
  eventRootDir = ""

suite "dmon test":
  test "todo: test dmon init":
    let cb: WatchCallback = proc(
        watchId: WatchId,
        action: DmonAction,
        rootDir, filepath, oldfilepath: string,
        userData: pointer,
    ) {.gcsafe.} =
      {.cast(gcsafe).}:
        echo "callback: ", "watchId: ", watchId.repr
        echo "callback: ", "action: ", action.repr
        echo "callback: ", "rootDir: ", rootDir.repr
        echo "callback: ", "file: ", filepath.repr
        echo "callback: ", "old: ", oldfilepath.repr
        eventFileModified = filepath
        eventRootdir = rootDir

    assert not getCurrentDir().endsWith("tests/"), "this test should be run from the dmon-nim root dir"

    initDmon()
    startDmonThread()

    echo("TEST: Starting...")
    let watchId: WatchId = watch("./tests/", cb, {Recursive}, nil)
    echo "TEST: watchId:repr: ", watchId.repr
    let watchId2: WatchId = watch("./src/", cb, {Recursive}, nil)

    echo("\nTEST: Waiting...")

    os.sleep(500)
    let testFile = "tests/file.txt".absolutePath
    let now1 = now()
    echo(fmt"TEST: Modifying {testFile} with {$now1}")
    writeFile(testFile, $now1)
    echo(fmt"Waiting...")

    for i in 1..100:
      if eventFileModified == "file.txt":
        break
      os.sleep(100)
    check eventFileModified == "file.txt"

    watchId.unwatch()
    deinitDmon()

