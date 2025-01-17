
--define:usingChronicles

when defined(windowsXC):
  # --os:usingChronicles
  --os:windows
  --cpu:amd64
  --gcc.exe:"x86_64-w64-mingw32-gcc"
  --gcc.linkerexe:"x86_64-w64-mingw32-gcc"
  --gcc.options.linker:""
  --gcc.cpp.options.linker:""
  --clang.options.linker:""
  --clang.cpp.options.linker:""
  --tcc.options.linker:""

