# Dmon

Monitor file changes in directories. Supports recursive file monitoring!

This is an idiomatic Nim port of the C library [dmon](https://github.com/septag/dmon) by [@septag](https://twitter.com/septagh). 

# Status

Platform support:
- [x] MacOS
- [x] Linux
- [x] FreeBSD
- [x] OpenBSD
- [x] NetBSD
- [~] Windows - compiles with wine but untested

## Watch capacity

The default limit is 64 simultaneous watches per process, shared by all callers.
Set the limit when compiling your application:

```sh
nim c -d:dmonMaxWatches=256 app.nim
```

The exported `dmonMaxWatches` constant reports the configured capacity. Values
must be positive and fit in a `WatchId`. macOS, Linux, and BSD allow larger
capacities; Windows supports at most 64 because its backend uses
`WaitForMultipleObjects`. Unsupported values fail at compile time.

Registering a watch when every slot is occupied raises `ValueError`. Releasing
a watch makes its slot available immediately. Increasing this limit does not
change operating-system resource limits or recursive-watch behavior.

Watch callbacks run on the monitor thread and may run while the watcher lock is
held. Queue registration and removal back to your application thread rather than
calling watch lifecycle functions from a callback.
