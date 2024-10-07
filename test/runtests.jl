using CacheBySpec
using CacheBySpec: ReadOnly
using StableHashTraits
using Test

@testset "CacheBySpec" begin
	include("deduplication.jl")
end
