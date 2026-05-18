using Test

# To run the testset xyz from the REPL:
# 1. activate test environment (or another environment with the relevant test dependencies installed)
# 2. includet("test/xyz.jl")
# 3. call run_xyz_tests()

include("hash.jl")
include("deduplicator.jl")
include("cache.jl")
include("spec.jl")
include("scheduler.jl")

@testset "ReproducibleJobs" begin
	run_hash_tests()
	@testset "Deduplicator" begin
		run_deduplicator_tests()
	end
	@testset "Cache" begin
		run_cache_tests()
	end
	run_spec_tests()
	run_scheduler_tests()
end
