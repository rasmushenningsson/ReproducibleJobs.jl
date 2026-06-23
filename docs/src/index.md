```@meta
CurrentModule = ReproducibleJobs
```

# ReproducibleJobs

`ReproducibleJobs.jl` is a framework for reproducible analyses of scientific data, that is based on the following ideas:

* The burden of reproducibility should be moved from the user to the packages they use for analysis, when possible.
* Memoization/caching is a good strategy because while the raw data can be large, the computed results are in essence much smaller.
* It is possible to create succinct specifications of how to perform analyses.

The main use case so far is [SingleCellProjections.jl](https://github.com/BioJulia/SingleCellProjections.jl).


## Installation
Install ReproducibleJobs.jl by running the following commands in Julia:

```julia
using Pkg
Pkg.add("ReproducibleJobs")
```
