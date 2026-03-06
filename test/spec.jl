using Test
using ReproducibleJobs
using ReproducibleJobs: create_spec, with_scheduler, SpecArgs, Fetch, Prefetch, ROVec


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

	@testset "fetched/prefetched" begin
		spec = create_spec(sin, 1)

		@testset "$f" for (f,T) in ((fetched,Fetch), (prefetched,Prefetch))
			let s = f(spec)
				@test s.op === T()
				@test s.sa === spec.sa
			end

			let t = f((1,spec))
				@test t[2].op === T()
				@test t[2].sa === spec.sa
			end

			let t2 = f((spec,spec))
				@test t2[1].op === T()
				@test t2[1].sa === spec.sa
				@test t2[2].op === T()
				@test t2[2].sa === spec.sa
			end

			let nt = f((; a=1, b=spec))
				@test nt.a === 1
				@test nt.b.op === T()
				@test nt.b.sa === spec.sa
			end

			let p = f(1=>spec)
				@test p[1] === 1
				@test p[2].op === T()
				@test p[2].sa === spec.sa
			end
			let p2 = f(spec=>2)
				@test p2[1].op === T()
				@test p2[1].sa === spec.sa
				@test p2[2] === 2
			end
			let p3 = f(spec=>spec)
				@test p3[1].op === T()
				@test p3[1].sa === spec.sa
				@test p3[2].op === T()
				@test p3[2].sa === spec.sa
			end

			let a = f([1,spec])
				@test a[1] === 1
				@test a[2].op === T()
				@test a[2].sa === spec.sa
			end

			let dict = f(Dict("key"=>spec))
				@test only(keys(dict)) == "key"
				@test dict["key"].op === T()
				@test dict["key"].sa === spec.sa
			end

			let dict2 = f(Dict(spec=>"value"))
				@test only(keys(dict2)).op === T()
				@test only(keys(dict2)).sa === spec.sa
				@test only(values(dict2)) == "value"
			end

			let set = f(Set((spec,2)))
				(v1,v2) = set
				v1 isa Spec || ((v1,v2) = (v2,v1)) # handle that order is not guaranteed
				@test v1.op === T()
				@test v1.sa === spec.sa
				@test v2 == 2
			end

			let r = f(Returns(spec))
				@test r.value.op === T()
				@test r.value.sa === spec.sa
			end

			let fix = f(isequal(spec))
				@test fix.f === isequal
				@test fix.x.op === T()
				@test fix.x.sa === spec.sa
			end

			let c = f(sin∘isequal(spec))
				@test c.outer === sin
				@test c.inner.f === isequal
				@test c.inner.x.op === T()
				@test c.inner.x.sa === spec.sa
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
				@test s isa Spec
				@test s.op === T()
				@test s.sa === spec.sa
			end
		end
	end
end

