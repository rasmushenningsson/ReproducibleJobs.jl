```@meta
CurrentModule = ReproducibleJobs
```

# User Guide

## Introduction

ReproducibleJobs.jl is a framework for lazy, cached computations.
Packages built on it — like
[SingleCellProjections.jl](https://github.com/BioJulia/SingleCellProjections.jl) —
use it to define analysis steps as [`Job`](@ref)s.
You typically don't create Jobs directly, but interact with them through the package's API.
Most of the complexity is handled for you.

Under the hood, each Job is identified by a hash of its function, arguments, and keyword arguments
(computed using [StableHashTraits.jl](https://github.com/beacon-biosignals/StableHashTraits.jl)).
Results are cached to disk, so you don't need to recompute when you come back later — even across Julia sessions.
Before computation, Jobs go through a *preprocessing* phase that can transform the computation graph — for example,
creating canonical representations of computations so that equivalent analyses produce the same hash
regardless of how they were specified.


## Computing results with `fetch!`

[`fetch!`](@ref) is the way to compute a result:

```julia
result = fetch!(job)
```

`fetch!` resolves all dependencies and preprocessing steps automatically.
If the result has been computed before, it is returned from cache without recomputation.

!!! note "fetch!"
    Avoid calling `fetch!` unless you actually need the result. Let `ReproducibleJobs.jl` decide
    what is computed and retrieved from the cache. Often, an early computation step (e.g. loading
    raw data) does not need to be performed at all if a later step is already cached to disk.


## Jobs and results are read-only

Results returned by [`fetch!`](@ref) must not be mutated.

Arrays are wrapped in `ReadOnlyArray` (from
[ReadOnlyArrays.jl](https://github.com/JuliaArrays/ReadOnlyArrays.jl))
to help enforce this, but not all types can be protected — `DataFrame`s and other mutable
types rely on user discipline. There is simply no way in Julia to enforce read-only behavior for
most existing types.

!!! warning "Read-only"
    Mutating results or Jobs after they are created is considered undefined behavior.
    Doing so corrupts the on-disk and in-memory caches in unpredictable ways.
    If you need to mutate a result, do a proper `copy` first.


## Setting up the cache

By default, results are cached in a `.cache` directory in the working directory.
To use a different location, call [`persist_cache_path!`](@ref):

```julia
persist_cache_path!("/path/to/cache")
```

This stores the path in `LocalPreferences.toml` (via
[Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)),
so it persists across sessions. Use [`get_cache_path`](@ref) to check the current setting.

!!! warning
    Only one Julia process can interact with a given cache folder at a time.


## Inspecting the computation graph

[`forward!`](@ref) resolves all preprocessing steps without computing the final result.
This is useful for understanding how a computation will be structured:

```julia
resolved_job = forward!(job)
```

[`forward_once!`](@ref) resolves a single preprocessing step at a time, allowing
step-by-step inspection of how preprocessing transforms the computation graph.

If you want to inspect a job in more detail, use [`print_spec`](@ref) with `max_depth` to see more levels of the call graph.

```julia
print_spec(job; max_depth=10)
```


## Referring to files

Packages built on ReproducibleJobs handle file references for you — for example,
`load_counts` in SingleCellProjections.jl takes care of this automatically.

Under the hood, file paths go through a three-step pipeline:
1. **Raw path** — a plain `String`.
2. **[`TimestampedFilePath`](@ref)** — Keeps track of the path and its modification time (`mtime`).
3. **[`ChecksummedFilePath`](@ref)** — computes and caches the file's SHA-256 checksum based on path and `mtime`. This means that e.g. moving/renaming/touching a file without changing its contents does not force recomputation of downstream steps.


## How it works

At a conceptual level, the system has the following components:

- **[`Spec`](@ref)**: An immutable description of a computation — a function plus its arguments and keyword arguments. This is the building block of the computation graph.
- **Deduplication**: Structurally identical specs automatically share the same in-memory handle (via the [`Deduplicator`](@ref)), avoiding redundant computation and memory waste.
- **[`Scheduler`](@ref)**: Manages execution, preprocessing, and caching. Processes Jobs by first resolving preprocessing steps, then computing results.
- **Caching**: Results are cached in an in-memory LRU cache (for fast repeated access) and on disk in JLD2 format (for persistence across sessions). 
- **Preprocessing**: Some Jobs include transformation steps (via [`Preprocess`](@ref)) that run before the final computation. Preprocessing can rewrite the computation graph — this is how packages like SingleCellProjections.jl implement projections and canonical representations.


## Threading

ReproducibleJobs uses Julia's multi-threading to run computations in the background.
Make sure to [start Julia with multiple threads](https://docs.julialang.org/en/v1/manual/multi-threading/)
for best performance.

The main thread is kept free for showing progress and handling user interaction.
This means that `Ctrl+C` interrupts are handled gracefully — running computations
are able to cancel cleanly rather than being abruptly killed.


## Debugging failures

When a computation fails, ReproducibleJobs captures the failure for inspection:

- [`get_failed_job`](@ref)`()` returns the most recently failed [`Job`](@ref), or `nothing` if no failure has occurred.
- [`get_failed_spec`](@ref)`()` returns the innermost [`Spec`](@ref) that caused the failure. In this spec, argument Jobs have been replaced by their actual computed values, making it easier to understand what went wrong.
