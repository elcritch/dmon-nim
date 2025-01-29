
--define:dmonEnableChronicles
--define:"chronicles_log_level:TRACE"
--define:"chronicles_sinks:textlines"
--define:"chronicles_indent:2"
--define:"chronicles_timestamps:NoTimestamps"


when defined(windowsXC):
  # --os:dmonEnableChronicles
  --os:windows
  --cpu:amd64
  --gcc.exe:"x86_64-w64-mingw32-gcc"
  --gcc.linkerexe:"x86_64-w64-mingw32-gcc"
  --gcc.options.linker:""
  --gcc.cpp.options.linker:""
  --clang.options.linker:""
  --clang.cpp.options.linker:""
  --tcc.options.linker:""

