using Test
using ReproducibleJobs
using ReproducibleJobs.Deduplicators
using ReproducibleJobs.Deduplicators: Hash, hash_string
using StableHashTraits

function run_hash_tests()
	@testset "Hash" begin
		h = Hash(stable_hash("abcd"; version=4))
		@test hash_string(h) == "22c2ba5f5b99981344c4fef160d0fa0a4e8ebf218858fdca8aec8721bc8c71ef"
		h2 = Hash(hash_string(h))
		@test h2 === h
	end
end
