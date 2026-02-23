using ReproducibleJobs
using Test

@testset "ReproducibleJobs" begin
	# include("deduplication.jl")
	include("Deduplicators/runtests.jl")
end
