using Test

# To run the testset xyz from the REPL:
# 1. activate test environment (or another environment with the relevant test dependencies installed)
# 2. includet("test/xyz.jl")
# 3. call run_xyz_tests()

include("spec.jl")

@testset "ReproducibleJobs" begin
	include("Deduplicators/runtests.jl")
	run_spec_tests()
end
