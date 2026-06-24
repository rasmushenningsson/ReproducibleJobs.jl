using Test
using ReproducibleJobs
using ReproducibleJobs: ROVec, create_job, fetched, prefetched, with_scheduler


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
	@testset "Comparisons" begin
		@testset "Basic comparisons" begin
			spec = create_job(sin, 1)

			spec2 = create_job(sin, 1)
			@test spec === spec2

			spec3 = create_job(sin, 2)
			@test !isequal(spec, spec3)

			spec4 = create_job(sin, 1; deduplicator=nothing)
			@test spec !== spec4
			@test isequal(spec, spec4)

			spec5 = create_job(sin, 1.0)
			@test spec !== spec5 # Not the same spec because types are different.
			@test isequal(spec, spec5) # Equal because isequal(1,1.0) - is that what we want?
		end

		@testset "Vector" begin
			a = create_job(sin, [1,5,2])
			b = create_job(sin, [1,5,2]; deduplicator=nothing)
			@test a !== b # Because b wasn't deduplicated.
			@test isequal(a, b)
		end

		@testset "Comparisons with missing" begin
			let
				spec = create_job(sin, missing)
				spec2 = create_job(sin, missing)
				@test spec === spec2
				@test isequal(spec, spec2)
			end

			let
				spec = create_job(sin, 1, missing)
				spec2 = create_job(sin, 2, missing)
				@test spec !== spec2
				@test !isequal(spec, spec2)
			end

			let
				spec = create_job(sin, missing, 1)
				spec2 = create_job(sin, missing, 2)
				@test spec !== spec2
				@test !isequal(spec, spec2)
			end
		end

		@testset "Comparison edge cases" begin
			@testset "Returns" begin
				a = create_job(sin, Returns("a"))
				b = create_job(sin, Returns("a"); deduplicator=nothing)
				@test a !== b # Because b wasn't deduplicated.
				@test isequal(a, b)
			end
			@testset "Returns Vector" begin
				a = create_job(sin, Returns([1,2,3]))
				b = create_job(sin, Returns([1,2,3]); deduplicator=nothing)
				@test a !== b # Because b wasn't deduplicated.
				@test isequal(a, b)
			end
			@testset "Base.Fix" begin
				a = create_job(sin, startswith("a"))
				b = create_job(sin, startswith("a"); deduplicator=nothing)
				@test a !== b # Because b wasn't deduplicated.
				@test isequal(a, b)
			end
			@testset "ComposedFunction" begin
				a = create_job(sin, !startswith("a"))
				b = create_job(sin, !startswith("a"); deduplicator=nothing)
				@test a !== b # Because b wasn't deduplicated.
				@test isequal(a, b)
			end
		end
	end

	@testset "$f" for (f,op) in ((fetched,:fetch), (prefetched,:prefetch))
		spec = create_job(sin, 1)
		let s = f(spec)
			@test s.op === op
			@test s.sr === spec.sr
		end

		let t = f((1,spec))
			@test t[2].op === op
			@test t[2].sr === spec.sr
		end

		let t2 = f((spec,spec))
			@test t2[1].op === op
			@test t2[1].sr === spec.sr
			@test t2[2].op === op
			@test t2[2].sr === spec.sr
		end

		let nt = f((; a=1, b=spec))
			@test nt.a === 1
			@test nt.b.op === op
			@test nt.b.sr === spec.sr
		end

		let p = f(1=>spec)
			@test p[1] === 1
			@test p[2].op === op
			@test p[2].sr === spec.sr
		end
		let p2 = f(spec=>2)
			@test p2[1].op === op
			@test p2[1].sr === spec.sr
			@test p2[2] === 2
		end
		let p3 = f(spec=>spec)
			@test p3[1].op === op
			@test p3[1].sr === spec.sr
			@test p3[2].op === op
			@test p3[2].sr === spec.sr
		end

		let a = f([1,spec])
			@test a[1] === 1
			@test a[2].op === op
			@test a[2].sr === spec.sr
		end

		let dict = f(Dict("key"=>spec))
			@test only(keys(dict)) == "key"
			@test dict["key"].op === op
			@test dict["key"].sr === spec.sr
		end

		let dict2 = f(Dict(spec=>"value"))
			@test only(keys(dict2)).op === op
			@test only(keys(dict2)).sr === spec.sr
			@test only(values(dict2)) == "value"
		end

		let set = f(Set((spec,2)))
			(v1,v2) = set
			v1 isa Job || ((v1,v2) = (v2,v1)) # handle that order is not guaranteed
			@test v1.op === op
			@test v1.sr === spec.sr
			@test v2 == 2
		end

		let r = f(Returns(spec))
			@test r.value.op === op
			@test r.value.sr === spec.sr
		end

		let fix = f(isequal(spec))
			@test fix.f === isequal
			@test fix.x.op === op
			@test fix.x.sr === spec.sr
		end

		let c = f(sin∘isequal(spec))
			@test c.outer === sin
			@test c.inner.f === isequal
			@test c.inner.x.op === op
			@test c.inner.x.sr === spec.sr
		end

		let nested = f(Set([Dict("k"=>[1=>(;a=(spec,))])]))
			@test nested isa Set
			dict = only(nested)
			@test dict isa Dict
			v = dict["k"]
			@test v isa ROVec
			p = only(v)
			@test p isa Pair
			nt = p[2]
			@test nt isa NamedTuple
			t = nt.a
			@test t isa Tuple
			s = only(t)
			@test s.op === op
			@test s.sr === spec.sr
		end
	end
end

