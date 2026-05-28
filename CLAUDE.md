# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

**Run all tests:**
```
jp -e `using Pkg; Pkg.test("ReproducibleJobs")`
```

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
Then watch it live in another terminal:
```
watch -n 0.1 --color "cat progress.log"
```

**Configure the on-disk cache path:**
```julia
using ReproducibleJobs
ReproducibleJobs.Deduplicators.persist_cache_path!("/path/to/cache")
```
This writes a Julia Preference; the default is `.cache` in the working directory.

## Architecture

### Core Concepts

**`Spec`** (`src/spec.jl`): A specification of a computation — a function `f` plus `args` and `kwargs`. Specs are deduplicated by default (same spec === same object in memory). `create_spec(f, args...; kwargs...)` is the main constructor. All non-preprocessing specs must include a `__version` kwarg (stripped before calling `f`). `op` field controls how the Spec is processed: `Call` (ready), `Fetch` (compute immediately), `Prefetch` (collapse to result before calling parent), `Forward` (still being forwarded through preprocessing).

**`Job`** (`src/job.jl`): User-facing wrapper around a `Spec`. Holds a cached `result` field. Call `fetch!(job)` to compute, `forward(job)` to run preprocessing only.

**`Scheduler`** (`src/scheduler.jl`): Single-threaded executor. Owns a `Deduplicator` and a `Cache`. Processes specs by forwarding through preprocessing, then computing. The global scheduler is accessed via `get_scheduler()` / `set_scheduler!()` / `with_scheduler(f, s)`. On-disk caching is activated via `cached(spec)`.

**`Deduplicator`** (`src/Deduplicators/deduplicator.jl`): Ensures structurally equal mutable objects share the same memory reference. Uses `StableHashTraits` for content hashing plus a pointer→(weakref, hash) map. Types opt-in via `deduplicate_type(::Type{T}) = true`. Arrays become `ReadOnlyArray`s after deduplication to prevent mutation.

**`Cache`** (`src/Deduplicators/cache.jl`): Two-level cache keyed by `SpecArgs`. In-memory level is a `WeakKeyDict` using `deconstruct_weak_rec`/`reconstruct_weak_rec` to hold values weakly. On-disk level stores JLD2 files named by hash. `cache_get!(f, cache, key; use_disk)` is the main entry point.

**`Preprocess` / `Preprocessing`** (`src/preprocess.jl`): Wraps a function to mark it as a preprocessing step. Preprocessing functions receive a `Preprocessing{E}()` sentinel as their first argument. The scheduler calls preprocessing specs via `forward!`/`forward_once!` before computing dependencies. `Preprocess{true}` (early) vs `Preprocess{false}` (late) controls ordering among nested preprocessing steps. `should_forward_child` rules determine which parent/child combos are forwarded.

**`CompoundResult`** (`src/Deduplicators/compound_result.jl`): A named collection of heterogeneous results (`keys::ROVec{String}`, `values::Vector`). Used with `cached(spec, sub_key)` to load individual sub-results from disk without loading the entire result.

**`TimestampedFilePath` / `ChecksummedFilePath`** (`src/paths.jl`): File path wrappers that capture `mtime` or SHA-256 checksum so file changes invalidate cached computations. `ChecksummedFilePath` equality is based solely on checksum, allowing cached results to survive file renames.

### Data Flow

```
Job → fetch!(job)
        └→ Scheduler.process!(spec, Fetch)
              ├─ Forward phase: expand preprocessing specs (forward! loop)
              │    └─ preprocessing f receives Preprocessing{E}() and returns new SpecArgs
              └─ Compute phase (all deps have op=Call):
                    ├─ cache_get!(cache, sa; use_disk=false)  [in-memory]
                    └─ cache_get!(cache, sa; use_disk=true)   [on-disk, for cached() specs]
                          └─ f(args...; kwargs...)  [kwargs with __ prefix are stripped]
```

### Adding Support for New Types

To deduplicate a new mutable type, implement:
- `Deduplicators.deduplicate_type(::Type{MyType}) = true`
- `Deduplicators.deduplication_pointer(x::MyType)` → `pointer_from_objref(x)`
- `Deduplicators.deduplicate_children!(d, x::MyType; kwargs...)` → returns deduplicated version
- `Deduplicators.deduplication_hash(d, x::MyType)` → `Hash`
- `Deduplicators.deduplication_copy(x::MyType)`

For disk persistence also implement `cache_save(io, name, x::MyType)` and `cache_load(cache, ::Val{:MyType}, g)`.

For reconstructable value types, implement `deconstruct_type`, `deconstruct`, `reconstruct`, `type_to_tag`, `tag_to_type` instead.
