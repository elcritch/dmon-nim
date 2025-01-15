import pkg/macosutils

proc createDefaultCFAllocator*(): CFAllocatorRef =
  proc dmonCfMalloc(allocSize: CFIndex, hint: CFOptionFlags, info: pointer): pointer {.cdecl.} =
    trace "dmonCfMalloc ", allocSize = allocSize
    result = alloc(allocSize.csize_t)

  proc dmonCfFree(pt: pointer, info: pointer) {.cdecl.} =
    trace "dmonCfFree ", info = info.repr
    if pt != nil:
      dealloc(pt)

  proc dmonCfRealloc(pt: pointer, newsize: CFIndex, hint: CFOptionFlags, 
                    info: pointer): pointer {.cdecl.} =
    trace "dmonCfRealloc ", newsize = newsize, info = info.repr
    result = realloc(pt, newsize.csize_t)

  var ctx = CFAllocatorContext(
    version: 0,
    info: nil,
    retain: nil,
    release: nil,
    copyDescription: nil,
    allocate: dmonCfMalloc,
    reallocate: dmonCfRealloc,
    deallocate: dmonCfFree,
    preferredSize: nil
  )
  
  result = CFAllocatorCreate(nil.CFAllocatorRef, addr ctx)

