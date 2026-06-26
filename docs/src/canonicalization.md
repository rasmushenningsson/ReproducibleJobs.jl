```@meta
ShareDefaultModule = true # All unnamed setup/example/repl blocks share the same module, so we can just keep adding stuff and reuse old variables
```

# Canonicalization

Before a spec's arguments are hashed to produce its cache key, they are normalized to a *canonical form*.
This matters because the same logical value can arise with different compile-time types depending on how a pipeline was constructed.
Canonicalization ensures that these representations hash identically, so they refer to the same cached result.

Notable cases:

- **Arrays with unnecessarily wide eltypes**: a `Vector{Union{Nothing,Int}}` that contains no `nothing` elements is canonicalized to `Vector{Int}`.
- **AbstractArrays**: any non-`Array` AbstractArray (views, ranges, subarrays) is materialized to a plain `Array` before hashing. (Exception: `SparseMatrixCSC` and `SparseVector` are kept in their sparse form.)
- **AbstractStrings**: any `AbstractString` (e.g. a `SubString`) is converted to a plain `String`.
- **NamedTuples**: fields are sorted by name before hashing, so `(b=2, a=1)` and `(a=1, b=2)` are treated as equal arguments.

In the example below, `indexin` returns a `Vector{Union{Nothing,Int}}` — it can return `nothing` for elements not found, so the return type always allows it. Here all elements are found, so the values are `[1,3,5]`, the same as the explicit `Vector{Int}` passed to `job`. After canonicalization, both vectors are treated as identical, and `job2` resolves to the same object as `job`:


```@setup
using ReproducibleJobs: create_job
function my_job end
```

```@example
job = create_job(my_job, [1,3,5])
```

```@example
ind = indexin(['A','C','E'], 'A':'Z')
```

```@example
job2 = create_job(my_job, ind)
```

```@example
job === job2
```


