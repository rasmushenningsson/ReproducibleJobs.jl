@testset "pass-through" begin
	dedup = Deduplicator(HashVersion{4}())

	@test dedup(5) === 5
	@test dedup(5.3) === 5.3
	@test dedup("string") === "string"
	@test dedup(:symbol) === :symbol
	@test dedup(11:16) === 11:16
	@test dedup(11:3.5:570) === 11:3.5:570
	@test dedup(v"1.2.3") === v"1.2.3"
	@test dedup(v"1.2.3-rc1") === v"1.2.3-rc1"

	@test length(dedup.d) == 0
end

@testset "Array" begin
	dedup = Deduplicator(HashVersion{4}())

	vi = [4,5,6]
	roi = dedup(vi)
	@test roi.value === vi
	@test length(dedup.d) == 1

	roi2 = dedup(copy(vi))
	@test roi2 === roi
	@test length(dedup.d) == 1

	vf = Float64[4,5,6]
	rof = dedup(vf)
	@test rof.value === vf
	@test roi !== rof # ensure Int array and float array deduplicated (hashed) differently
	@test length(dedup.d) == 2
end

@testset "Tuple" begin
	dedup = Deduplicator(HashVersion{4}())

	@test dedup((1234,"hello")) === (1234,"hello") # pass-through
	@test length(dedup.d) == 0

	t = (4, dedup([1,6]))
	@test dedup(t) === t
	@test length(dedup.d) == 1
end

@testset "NamedTuple" begin
	dedup = Deduplicator(HashVersion{4}())

	@test dedup((;a=1234,b="hello")) === (;a=1234,b="hello") # pass-through
	@test length(dedup.d) == 0

	nt = (;u=4,v=dedup([1,6]))
	@test dedup(nt) === nt
	@test length(dedup.d) == 1
end

@testset "ReadOnly" begin
	dedup = Deduplicator(HashVersion{4}())

	x = [1,5,10]
	
	ro = ReadOnly(x, "dummy_hash")
	ro2 = dedup(ro)
	@test ro != ro2
	@test ro !== ro2

	ro3 = ReadOnly(copy(x), "dummy_hash")
	# before dedup
	@test ro3 == ro
	@test ro3 !== ro
	ro4 = dedup(ro3)
	# after dedup
	@test ro4 == ro2
	@test ro4 != ro
	@test ro4 != ro3
	@test ro4 === ro2
	@test ro4 !== ro
	@test ro4 !== ro3
	@test length(dedup.d) == 1
end
