# To run the testset xyz from the REPL:
# 1. activate test environment (or another environment with the relevant test dependencies installed)
# 2. includet("test/xyz.jl")
# 3. call run_xyz_tests()

include("hash.jl")
include("deduplicator.jl")
include("cache.jl")

@testset "Deduplicators.jl" begin
	run_hash_tests()
	run_deduplicator_tests()
	run_cache_tests()
end
