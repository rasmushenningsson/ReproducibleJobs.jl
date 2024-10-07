@testset "pass-through" begin
	dedup = Deduplicator(HashVersion{4}())

	@test deduplicate!(dedup, 5) === 5
	@test deduplicate!(dedup, 5.3) === 5.3
	@test deduplicate!(dedup, "string") === "string"
	@test deduplicate!(dedup, :symbol) === :symbol
	@test deduplicate!(dedup, 11:16) === 11:16
	@test deduplicate!(dedup, 11:3.5:570) === 11:3.5:570

	@test length(dedup.d) == 0
end

@testset "arrays" begin
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

@testset "read-only" begin
	dedup = Deduplicator(HashVersion{4}())

	x = [1,5,10]
	
	ro = ReadOnly(x, "dummy_hash")
	ro2 = deduplicate!(dedup, ro)
	@test ro === ro2

	ro3 = ReadOnly(copy(x), "dummy_hash")
	@test ro3 !== ro # before dedup
	ro4 = deduplicate!(dedup, ro3)
	@test ro4 === ro # after dedup
end
