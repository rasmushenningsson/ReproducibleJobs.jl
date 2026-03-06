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
		@test spec != spec3
		@test !isequal(spec, spec3)

		spec4 = create_spec(sin, 1; deduplicator=nothing)
		@test spec !== spec4
		@test spec == spec4
		@test isequal(spec, spec4)

		spec5 = create_spec(sin, 1.0)
		@test spec !== spec5 # Not the same spec because types are different.
		@test spec == spec5 # Equal because 1 == 1.0 - is that what we want?
		@test isequal(spec, spec5) # Equal because isequal(1,1.0) - is that what we want?
	end

	@testset "Comparisons with missing" begin
		let spec = create_spec(sin, missing), spec2 = create_spec(sin, missing)
			@test spec === spec2
			@test ismissing(spec == spec2)
			@test isequal(spec, spec2)
		end

		let spec = create_spec(sin, 1, missing), spec2 = create_spec(sin, 2, missing)
			@test spec !== spec2
			@test spec != spec2
			@test !isequal(spec, spec2)
		end

		let spec = create_spec(sin, missing, 1), spec2 = create_spec(sin, missing, 2)
			@test spec !== spec2
			@test spec != spec2
			@test !isequal(spec, spec2)
		end
	end

	@testset "Comparison edge cases" begin
		let spec = create_spec(sin, startswith("a")), spec2 = create_spec(sin, startswith("a"); deduplicator=nothing)
			@test spec !== spec2 # Because spec2 wasn't deduplicated.
			@test spec == spec2 # We handle this case by destructing Base.Fix and then comparing contents using ==
			@test isequal(spec, spec2)
		end
	end


end

