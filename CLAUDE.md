# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

**Run all tests:**
```
jp -e `using Pkg; Pkg.test("ReproducibleJobs")`
```

**Run a single testset via julia-mcp** (preferred — persistent session, no restart needed):
```julia
includet("dev/ReproducibleJobs/test/cache.jl")
run_cache_tests()
```
Each test file exposes a `run_<name>_tests()` function. `includet` ensures Revise tracks changes to the test file and only needs to be called once per session.

**Run a single testset from the REPL:**
```julia
# 1. Activate the test environment
# 2. includet("test/spec.jl")
# 3. run_spec_tests()
```
Each test file exposes a `run_<name>_tests()` function for interactive use.

Or, from the terminal:
1. Go to the test directory inside the package.
2. Run `jp -e 'include("cache.jl"); run_cache_tests()'`
(and similar for other testsets)

**Redirect progress display to a log file** (useful when stdout is not a TTY, e.g. inside Claude Code):
```julia
using ReproducibleJobs
ReproducibleJobs.set_progress_display!(ProgressDisplay(;io=WatchableLog("progress.log", 8)))
```
The file is overwritten from the top on every tick (seek + truncate), so `cat`-ing the whole
file always gives the current snapshot. The file ends with `--- Done ---` when the run completes.

In a regular terminal, watch it live with color:
```
watch -n 0.1 --color "cat progress.log"
```

Inside Claude Code (no TTY, `watch` doesn't work), use a shell loop instead:
```bash
while true; do cat progress.log; sleep 1; done
```
Or just `cat progress.log` on demand to see the current state.

**Configure the on-disk cache path:**
```julia
using ReproducibleJobs
ReproducibleJobs.persist_cache_path!("/path/to/cache")
```
This writes a Julia Preference; the default is `.cache` in the working directory.

## Architecture

### Core Concepts

**`Spec`** (`src/spec.jl`): A specification of a computation — a function `f` plus `args` and `kwargs`. `create_spec(f, args...; kwargs...)` is the main constructor. All non-preprocessing specs must include a `__version` kwarg (stripped before calling `f`).

**`Job`** (`src/spec.jl`): The primary user-facing type. Type alias `Job = SpecRef{State}`. A reference to a `SpecRun` with an `op` symbol (`:forward`, `:call`, `:fetch`, or `:prefetch`) that controls how it is processed. Call `fetch!(job)` to compute, `forward!(job)` to run preprocessing only.

**`SpecRun`** (`src/spec.jl`): The live, deduplicated handle for a spec. Holds the current `state` (one of `Initialized`, `Waiting`, `Processing`, `Next`, `Result`, `Errored`). `Result` contains both a strong `result` field and a weakly-held `weak_result` (via `deconstruct_weak_rec`). The LRU cache on `Scheduler` keeps the strong reference alive for recently used specs; on eviction the strong reference is cleared but `weak_result` persists. If the user still holds the result object the weak reference revives it; otherwise the spec re-runs.

**`Scheduler`** (`src/scheduler.jl`): Async executor (uses `Threads.@spawn` for a worker task). Owns a `Deduplicator`, a `Cache`, and an `LRUCache`. Processes specs by forwarding through preprocessing, then computing. The global scheduler is accessed via `get_scheduler()` / `set_scheduler!()` / `with_scheduler(f, s)`. On-disk caching is activated via `cached(spec)`.

**`Deduplicator`** (`src/deduplicator.jl`): Ensures structurally equal mutable objects share the same memory reference. Uses `StableHashTraits` for content hashing plus a pointer→(weakref, hash) map. Types opt-in via `deduplicate_type(::Type{T}) = true`. Arrays become `ReadOnlyArray`s after deduplication to prevent mutation.

**`Cache`** (`src/cache.jl`): On-disk cache keyed by `SpecRun`. Stores JLD2 files named by hash. `cache_get!(f, cache, key)` is the main entry point.

**`Preprocess` / `Preprocessing`** (`src/preprocess.jl`): Wraps a function to mark it as a preprocessing step. Preprocessing functions receive a `Preprocessing{E}()` sentinel as their first argument. The scheduler calls preprocessing specs via `forward!`/`forward_once!` before computing dependencies. `Preprocess{true}` (early) vs `Preprocess{false}` (late) controls ordering among nested preprocessing steps. `should_forward_child` rules determine which parent/child combos are forwarded.

**`CompoundResult`** (`src/compound_result.jl`): A named collection of heterogeneous results (`keys::ROVec{String}`, `values::Vector`). Used with `cached(spec, sub_key)` to load individual sub-results from disk without loading the entire result.

**`TimestampedFilePath` / `ChecksummedFilePath`** (`src/paths.jl`): File path wrappers that capture `mtime` or SHA-256 checksum so file changes invalidate cached computations. `ChecksummedFilePath` equality is based solely on checksum, allowing cached results to survive file renames.

### Data Flow

```
Job → fetch!(job)
        └→ Scheduler.process!(sr, :fetch)
              ├─ Forward phase: expand preprocessing specs (forward! loop)
              │    └─ preprocessing f receives Preprocessing{E}() and returns new Spec args
              └─ Compute phase (all deps have op=:call):
                    ├─ get_result!(sr)                      [strong ref, or weak ref revival]
                    └─ cache_get!(cache, sr)                [on-disk JLD2, for cached() specs]
                          └─ f(args...; kwargs...)  [kwargs with __ prefix are stripped]
```

### Adding Support for New Types

To deduplicate a new mutable type, implement:
- `deduplicate_type(::Type{MyType}) = true`
- `deduplication_pointer(x::MyType)` → unique pointer (e.g. `pointer_from_objref(x)`)
- `deduplicate_children!(d, x::MyType; kwargs...)` → returns deduplicated version
- `deduplication_hash(d, x::MyType)` → `Hash`
- `deduplication_copy(x::MyType)`

For disk persistence also implement `cache_save(cache, io, name, x::MyType)` and `cache_load(cache, ::Val{:MyType}, g)`.

For reconstructable value types, implement `deconstruct_type`, `deconstruct`, `reconstruct`, `type_to_tag`, `tag_to_type` instead.
