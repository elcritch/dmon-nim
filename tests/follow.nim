# follow.nim

import
  selectors, tables, strformat, os

type
  FileSource = object
    path: string
    file: File

proc monitorsFiles() =
  let names = ["tests/file.txt"]
  var sources: Table[int, FileSource]
  
  for name in names:
    let file = open(name, fmRead)
    file.setFilePos(0, fspEnd)
    sources[file.getFileHandle()] = FileSource(path: name, file: file)
  
  let selector = newSelector[int]()
  let events = {Read}
  
  for source in sources.values:
    selector.registerHandle(source.file.getFileHandle(), events, 0)
  
  echo fmt"Monitoring files..."
  while true:
    try:
      let triggers = selector.select(500)
      if triggers.len > 0:
        for trigger in triggers:
          if trigger.events == {Read}:
            assert trigger.errorCode == 0.OSErrorCode
            let source = sources[trigger.fd]
            stdout.write fmt"{source.path}: {source.file.readAll()}"
    
    except IOSelectorsException:
      sleep(100)

monitorsFiles()
