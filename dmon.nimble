# Package

version       = "0.4.0"
author        = "Jaremy Creechley"
description   = "Library to monitor file changes in a folder. A port of Dmon."
license       = "BSD-2-Clause"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0"
requires "macosutils >= 0.3.2"
requires "winim >= 3.9.4"

when defined(dmonEnableChronicles):
  requires "chronicles >= 0.10.0"
