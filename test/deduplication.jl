@testset "pass-through" begin
	dedup = Deduplicator(HashVersion{4}())

	@test deduplicate!(dedup, 5) === 5
	@test deduplicate!(dedup, 5.3) === 5.3
	@test deduplicate!(dedup, "string") === "string"
	@test deduplicate!(dedup, :symbol) === :symbol
	@test deduplicate!(dedup, 11:16) === 11:16
	@test deduplicate!(dedup, 11:3.5:570) === 11:3.5:570
	@test deduplicate!(dedup, v"1.2.3") === v"1.2.3"
	@test deduplicate!(dedup, v"1.2.3-rc1") === v"1.2.3-rc1"

	@test length(dedup.d) == 0
end

@testset "Array" begin
	dedup = Deduplicator(HashVersion{4}())

	vi = [4,5,6]
	roi = deduplicate!(dedup, vi)
	@test roi.value == vi
	@test roi.value !== vi # ensure a copy was made
	@test length(dedup.d) == 1

	roi2 = deduplicate!(dedup, copy(vi))
	@test roi2 === roi
	@test length(dedup.d) == 1

	vf = Float64[4,5,6]
	rof = deduplicate!(dedup, vf)
	@test rof.value == vf
	@test rof.value !== vf # ensure a copy was made
	@test roi !== rof # ensure Int array and float array deduplicated (hashed) differently
	@test length(dedup.d) == 2
end

@testset "Tuple" begin
	dedup = Deduplicator(HashVersion{4}())

	@test deduplicate!(dedup, (1234,"hello")) === (1234,"hello") # pass-through
	@test length(dedup.d) == 0

	t = (4,[1,6])
	ro = deduplicate!(dedup, t)
	@test ro isa ReadOnly
	@test ro.value == t
	@test ro.value !== t # ensure a copy was made
	@test length(dedup.d) == 1

	ro2 = deduplicate!(dedup, deepcopy(t))
	@test ro2 === ro
	@test length(dedup.d) == 1
end

@testset "NamedTuple" begin
	dedup = Deduplicator(HashVersion{4}())

	@test deduplicate!(dedup, (;a=1234,b="hello")) === (;a=1234,b="hello") # pass-through
	@test length(dedup.d) == 0

	nt = (;u=4,v=[1,6])
	ro = deduplicate!(dedup, nt)
	@test ro isa ReadOnly
	@test ro.value == nt
	@test ro.value !== nt # ensure a copy was made
	@test length(dedup.d) == 1

	ro2 = deduplicate!(dedup, deepcopy(nt))
	@test ro2 === ro
	@test length(dedup.d) == 1
end

@testset "ReadOnly" begin
	dedup = Deduplicator(HashVersion{4}())

	x = [1,5,10]
	
	ro = ReadOnly(x, "dummy_hash")
	ro2 = deduplicate!(dedup, ro)
	@test ro === ro2

	ro3 = ReadOnly(copy(x), "dummy_hash")
	@test ro3 !== ro # before dedup
	ro4 = deduplicate!(dedup, ro3)
	@test ro4 === ro # after dedup
	@test length(dedup.d) == 1
end
