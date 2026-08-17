using Test
using ReproducibleJobs
using ReproducibleJobs: Hash, hash_string, Deduplicator, compute_hash
using StableHashTraits

function run_hash_tests()
	@testset "Basic" begin
		h = Hash(stable_hash("abcd"; version=4))
		@test hash_string(h) == "22c2ba5f5b99981344c4fef160d0fa0a4e8ebf218858fdca8aec8721bc8c71ef"
		h2 = Hash(hash_string(h))
		@test h2 === h
	end

	@testset "Types" begin
		d = Deduplicator()
		h(x) = compute_hash(d, x)

		@testset "NumberType" begin
			@test h(0) != h(0.0)
			@test h(UInt64(1)) != h(Int64(1))
			@test h(Int32(1)) != h(UInt32(1))
			@test h(false) != h(0)
		end

		@testset "StringType" begin
			@test h('a') != h("a")
			@test h(v"1.2.3") != h("1.2.3")
			@test h(:a) != h("a")
		end
	end
end
