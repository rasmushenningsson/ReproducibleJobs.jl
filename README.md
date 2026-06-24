# ReproducibleJobs.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://rasmushenningsson.github.io/ReproducibleJobs.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://rasmushenningsson.github.io/ReproducibleJobs.jl/dev/)
[![Build Status](https://github.com/rasmushenningsson/ReproducibleJobs.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/rasmushenningsson/ReproducibleJobs.jl/actions/workflows/CI.yml?query=branch%3Amain)


ReproducibleJobs.jl is a framework for reproducible analyses of scientific data, that is based on the following ideas:

* The burden of reproducibility should be moved from the user to the packages they use for analysis, when possible.
* Memoization/caching is a good strategy because while the raw data can be large, the computed results are in essence much smaller.
* It is possible to create succinct specifications of how to perform analyses.

For more information, see the [documentation](https://rasmushenningsson.github.io/ReproducibleJobs.jl/dev/).

Currently, the main use case for ReproducibleJobs.jl is [SingleCellProjections.jl](https://github.com/BioJulia/SingleCellProjections.jl).
