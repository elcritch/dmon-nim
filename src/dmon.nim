
import dmon/dmontypes
export dmontypes

when defined(bsdTest):
  import dmon/dmon_bsd
  export dmon_bsd
elif defined(macosx):
  import dmon/dmon_macos
  export dmon_macos
elif defined(linux):
  import dmon/dmon_linux
  export dmon_linux
elif defined(bsd):
  import dmon/dmon_bsd
  export dmon_bsd
elif defined(windows):
  import dmon/dmon_windows
  export dmon_windows
else:
  {.error: "unsupported OS! Please consider porting for it. ".}
