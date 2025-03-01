using ReproducibleJobs
using ReproducibleJobs: ReadOnly
using StableHashTraits
using Test

@testset "ReproducibleJobs" begin
	include("deduplication.jl")
end
