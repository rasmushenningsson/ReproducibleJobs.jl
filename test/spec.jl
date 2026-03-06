using Test
using ReproducibleJobs
using ReproducibleJobs: create_spec, with_scheduler, SpecArgs


function run_spec_tests()
	@testset "Specs" begin
		let tmp = mktempdir() # Cleanup when Julia process exits - useful for inspecting
			with_scheduler(Scheduler(; dir=tmp)) do
				_run_spec_tests()
			end
		end
	end
end

function _run_spec_tests()
	@testset "Basic comparisons" begin
		spec = create_spec(sin, 1)
		
		spec2 = create_spec(sin, 1)
		@test spec === spec2

		spec3 = create_spec(sin, 2)
		@test !isequal(spec, spec3)

		spec4 = create_spec(sin, 1; deduplicator=nothing)
		@test spec !== spec4
		@test isequal(spec, spec4)

		spec5 = create_spec(sin, 1.0)
		@test spec !== spec5 # Not the same spec because types are different.
		@test isequal(spec, spec5) # Equal because isequal(1,1.0) - is that what we want?
	end

	@testset "Vector" begin
		a = create_spec(sin, [1,5,2])
		b = create_spec(sin, [1,5,2]; deduplicator=nothing)
		@test a !== b # Because b wasn't deduplicated.
		@test isequal(a, b)
	end

	@testset "Comparisons with missing" begin
		let
			spec = create_spec(sin, missing)
			spec2 = create_spec(sin, missing)
			@test spec === spec2
			@test isequal(spec, spec2)
		end

		let
			spec = create_spec(sin, 1, missing)
			spec2 = create_spec(sin, 2, missing)
			@test spec !== spec2
			@test !isequal(spec, spec2)
		end

		let
			spec = create_spec(sin, missing, 1)
			spec2 = create_spec(sin, missing, 2)
			@test spec !== spec2
			@test !isequal(spec, spec2)
		end
	end

	@testset "Comparison edge cases" begin
		@testset "Returns" begin
			a = create_spec(sin, Returns("a"))
			b = create_spec(sin, Returns("a"); deduplicator=nothing)
			@test a !== b # Because b wasn't deduplicated.
			@test isequal(a, b)
		end
		@testset "Returns Vector" begin
			a = create_spec(sin, Returns([1,2,3]))
			b = create_spec(sin, Returns([1,2,3]); deduplicator=nothing)
			@test a !== b # Because b wasn't deduplicated.
			@test isequal(a, b)
		end
		@testset "Base.Fix" begin
			a = create_spec(sin, startswith("a"))
			b = create_spec(sin, startswith("a"); deduplicator=nothing)
			@test a !== b # Because b wasn't deduplicated.
			@test isequal(a, b)
		end
		@testset "ComposedFunction" begin
			a = create_spec(sin, !startswith("a"))
			b = create_spec(sin, !startswith("a"); deduplicator=nothing)
			@test a !== b # Because b wasn't deduplicated.
			@test isequal(a, b)
		end
	end


end

