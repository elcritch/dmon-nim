
--define:usingChronicles

when defined(linux):
  --os:windows
  --cpu:amd64
  --gcc.exe:"x86_64-w64-mingw32-gcc"
  --gcc.linkerexe:"x86_64-w64-mingw32-ld"