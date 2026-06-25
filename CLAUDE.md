# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

**Run all tests:**
```
jp -e 'using Pkg; Pkg.test("ReproducibleJobs")'
```

**Run a single test suite via julia-mcp** (preferred — persistent session, no restart needed):
```julia
includet("dev/ReproducibleJobs/test/cache.jl")
run_cache_tests()
```
Each test file exposes a `run_<name>_tests()` function. `includet` ensures Revise tracks changes.

Available: `run_hash_tests`, `run_deduplicator_tests`, `run_cache_tests`, `run_spec_tests`, `run_scheduler_tests`.

**Redirect progress display to a log file** (useful when stdout is not a TTY, e.g. inside Claude Code):
```julia
ReproducibleJobs.set_progress_display!(ProgressDisplay(;io=WatchableLog("progress.log", 8)))
```
The file is overwritten from the top on every tick (seek + truncate), so `cat progress.log` always gives the current snapshot.

## Architecture

See `docs/src/userguide.md` for a detailed explanation of the computation model, caching, preprocessing, and file handling.

### Key Source Files

| File | Contents |
|------|----------|
| `src/spec.jl` | `Spec`, `SpecRun`, `SpecRef`/`Job`, `create_job`, state types |
| `src/scheduler.jl` | `Scheduler`, `process!`, `fetch!`, `forward!` |
| `src/preprocess.jl` | `Preprocess`, `Preprocessing`, forwarding logic |
| `src/deduplicator.jl` | `Deduplicator`, content-hashing, `ReadOnlyArray` wrapping |
| `src/cache.jl` | `Cache`, on-disk JLD2 storage |
| `src/lru_cache.jl` | In-memory LRU with weak-reference revival |
| `src/compound_result.jl` | `CompoundResult`, sub-key loading via `cached(spec, key)` |
| `src/paths.jl` | `TimestampedFilePath`, `ChecksummedFilePath` |
| `src/hash.jl` | `Hash` type, `stable_hash` wrappers |
| `src/ifelse.jl` | `ifelse_job` — conditional branching in the computation graph |
| `src/progress.jl` | `ProgressDisplay`, `ProgressBar` |
| `src/watchable_log.jl` | `WatchableLog` for non-TTY progress output |
| `src/spec_printing.jl` | `print_spec`, tree-based display |

### Key Conventions

- `create_job(f, args...; __version=v"X.Y.Z", kwargs...)` — all non-preprocessing specs require `__version`. The `__` prefix is stripped before calling `f`.
- `cached(spec)` — wraps a spec for on-disk caching. `cached(spec, "sub_key")` loads a single entry from a `CompoundResult`.
- `fetched(job)` — fetched jobs are replaced by their computed values when preprocessing, making the value available to the parent job during preprocessing.
- `prefetched(job)` — prefetched jobs are replaced by their computed values just before the parent spec is computed. The effect is that the parent spec's hash depends on the value of the prefetched job, not on the job itself.
- `deduplicate_type(::Type{T}) = true` — opts a type into deduplication. See `deduplicator.jl` for the full interface.
- `deconstruct_type` / `deconstruct` / `reconstruct` / `type_to_tag` / `tag_to_type` — implement these for types that should be broken apart for caching and weak-reference revival. See SingleCellProjections' `src/SingleCellProjections.jl` for examples (DataMatrix, SVD, Blocks, etc.).
- Results from `fetch!` are read-only. Arrays are wrapped in `ReadOnlyArray`; mutating any result is undefined behavior.
