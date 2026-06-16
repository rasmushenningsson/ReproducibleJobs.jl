# ReproducibleJobs.jl

ReproducibleJobs.jl is a framework for reproducible analyses of scientific data, that is based on the following ideas:

* The burden of reproducibility should be moved from the user to the packages they use for analysis, when possible.
* Memoization/caching is a good strategy because while the raw data can be large, the computed results are in essence much smaller.
* It is possible to create succinct specifications of how to perform analyses.

More information and documentation to come.

Currently, the main use case for ReproducibleJobs.jl is [SingleCellProjections.jl](https://github.com/BioJulia/SingleCellProjections.jl).
