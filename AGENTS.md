# Repository Guidelines

## Project Structure & Modules
- `src/dmon.nim`: Public entry point and platform routing.
- `src/dmon/`: Shared types, logging facade, and Linux, macOS, Windows, and BSD backends.
- `tests/`: Integration tests; `tests/config.nims` adds the source path.
- Root files: `dmon.nimble` (package manifest), `README.md` (usage), and `config.nims` (build options).

## Build, Test, and Development
- Install deps (Atlas workspace): `atlas install` (ensure `atlas` is installed and configured for your environment). Never use Nimble; always use Atlas and its `deps/` folder and generated `nim.cfg` dependency paths.
- Run all tests: `atlas-run tests`.
- Run one test locally: `atlas-run tests testwatchslots.nim`.
- Helpful flags: `-d:noLogging` disables logging; `-d:bsdTest` exercises the portable BSD backend on non-BSD hosts.

## Coding Style & Naming
- Indentation: 2 spaces; no tabs.
- Nim style: Types in `PascalCase`, procs and variables in `camelCase`, modules in lowercase or concise `lowerCamel`.
- Keep platform-specific implementation in its backend module and shared lifecycle behavior in `dmontypes.nim`.
- Formatting: run `nimpretty --backup:off` on touched Nim files.

## Testing Guidelines
- Tests are standalone Nim programs under `tests/`; use deterministic polling and isolated temporary directories for file-watcher behavior.
- Run all tests with `atlas-run tests`; run targeted tests before the full suite.
- For backend changes, compile the relevant cross-platform target and run natively when a host is available.
- Test both default chroniclers logging and `-d:noLogging` when changing logging integration.

## Commit & Pull Requests
- Commits: short, imperative mood (for example, `add BSD watcher backend`).
- PRs: include a clear description, supported platforms, logging or concurrency considerations, and test coverage notes.
- Requirements: `atlas-run tests` must pass; include regression tests for lifecycle fixes and update `README.md` when platform support changes.

## Security & Configuration Tips
- Watch callbacks run from backend worker threads; keep shared state synchronized and avoid retaining transient event-path buffers.
- Do not hand-edit Atlas-generated dependency paths in `nim.cfg`; correct requirements or Atlas configuration and regenerate them.
