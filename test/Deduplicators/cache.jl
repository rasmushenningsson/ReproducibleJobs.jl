using Test
using ReproducibleJobs
using ReproducibleJobs.Deduplicators
using ReproducibleJobs.Deduplicators: ROArray, ROVec, ROMat, ROBitArray, ROBitVec, ROBitMat, Hash, CustomStorage, hash_string, key2path, DeconstructedWeak, reconstruct_weak_rec, NotValid, CompoundResult, cache_get_subresult!
using ReadOnlyArrays
using StableHashTraits
using SparseArrays
using DataFrames
using HDF5 # For raw reading of .jld2 files for testing purposes
using H5Zzstd # For raw reading of .jld2 files for testing purposes


_reconstructed_type(::DeconstructedWeak{R}) where R = R


# This is a dummy implementation to keep Specs separate from the Deduplication/Cache machinery
mutable struct CacheKey
	f::String
end

Deduplicators.deduplicate_type(::Type{CacheKey}) = true
Deduplicators.deduplication_pointer(key::CacheKey) = pointer_from_objref(key)
Deduplicators.deduplicate_children!(d, key::CacheKey; transfer_ownership) = key
function Deduplicators.deduplication_hash(d, key::CacheKey)
	Deduplicators.compute_hash(d, (Deduplicators.TypeTag(:CacheKey), key.f))
end
Deduplicators.deduplication_copy(key::CacheKey) = CacheKey(key.f)



let compute_called::Bool = false
	global function key2result(key::CacheKey)
		compute_called = true
		[key.f] # Create a Vector because it will interact with the GC
	end

	# Checks if key2result() has been called and resets to false.
	global function compute_called!()
		r = compute_called
		compute_called = false
		r
	end
end

create_test_key(cache, f) = deduplicate!(cache.deduplicator, CacheKey(f))


# We wrap this in a function, because otherwise I do not get the GC to do anything
@noinline function _put_old_key!(cache::Cache; kwargs...)
	key = create_test_key(cache, "GC")
	r = cache_get!(()->key2result(key), cache, key; kwargs...)
	@test r == ["GC"]
end
function put_old_key!(cache::Cache; kwargs...)
	_put_old_key!(cache; kwargs...)
	GC.gc(true)
	cache
end

# We wrap this in a function, because otherwise I do not get the GC to do anything
@noinline function _put_old_result!(cache::Cache, key::CacheKey; kwargs...)
	cache_get!(()->key2result(key), cache, key; kwargs...)
end
function put_old_result!(cache::Cache, key::CacheKey; kwargs...)
	_put_old_result!(cache, key; kwargs...)
	GC.gc(true)
	cache
end


let key_count = 0
	global function new_key(cache)
		key_count += 1
		create_test_key(cache, "key$key_count")
	end
end

_contains(pattern::Any) = contains(pattern)
_contains((k,v)::Pair, (kpattern,vpattern)::Pair) = contains(k, kpattern) && contains(v, vpattern)
_contains(pattern::Pair) = x->_contains(x,pattern)

function _fuzzy_pop!(x::Vector, pattern)
	matches = findall(_contains(pattern), x)
	if length(matches) != 1 # not a unique match
		@warn "$pattern does not have exactly one match in $x."
		return false
	end
	deleteat!(x, only(matches))
	return true
end

_param2type(::Any, param::HDF5.Dataset) = read(param)
function _param2type(h5, param::HDF5.Datatype)
	name = HDF5.name(param)
	read(attributes(h5[name]), "julia_type")
end

function extract_jld2_types(h5; remove_standard_types=true)
	found_types = String[]
	found_custom = Pair{String,String}[]

	if haskey(h5, "_types")
		types = h5["_types"]

		for k in keys(types)
			julia_type = read(attributes(types[k]), "julia_type")
			if remove_standard_types
				julia_type.name == "Core.DataType" && continue # This is (almost) always there
			end

			if endswith(julia_type.name, "CustomStorage")
				written_type = read(attributes(types[k]), "written_type")
				param = h5[only(julia_type.parameters)] # dereference
				original_type = _param2type(h5, param)
				push!(found_custom, original_type.name => written_type.name)
			else
				push!(found_types, julia_type.name)
			end
		end
	end
	unique!(found_types)
	unique!(found_custom)
	found_types, found_custom
end



function run_cache_tests()
	@testset "Cache" begin
		@testset "Memory Only" begin
			@testset "Basic" begin
				cache = Cache(CacheKey, Deduplicator(); dir=nothing)

				key = create_test_key(cache, "basic")

				r = cache_get!(()->key2result(key), cache, key)
				@test r == ["basic"]
				@test compute_called!()

				r2 = cache_get!(()->key2result(key), cache, key)
				@test r2 == ["basic"]
				@test r2 === r
				@test !compute_called!()

				# Test that it works with a newly deduplicated key too
				key = create_test_key(cache, "basic")
				r3 = cache_get!(()->key2result(key), cache, key)
				@test r3 == ["basic"]
				@test r3 === r
				@test !compute_called!()

				another_key = create_test_key(cache, "another")

				another_r = cache_get!(()->key2result(another_key), cache, another_key)
				@test another_r == ["another"]
				@test compute_called!()
			end

			@testset "GC key" begin
				cache = Cache(CacheKey, Deduplicator(); dir=nothing)

				put_old_key!(cache)
				@test compute_called!()
				@test isempty(cache.mem)

				key = create_test_key(cache, "GC")

				r = cache_get!(()->key2result(key), cache, key)
				@test r == ["GC"]
				@test compute_called!()
			end

			@testset "GC result" begin
				cache = Cache(CacheKey, Deduplicator(); dir=nothing)

				key = create_test_key(cache, "GC")

				put_old_result!(cache, key)
				@test compute_called!()
				@test reconstruct_weak_rec(only(values(cache.mem))) === NotValid() # Test that cached result has been GCed

				r = cache_get!(()->key2result(key), cache, key)
				@test r == ["GC"]
				@test compute_called!()
			end
		end


		@testset "Using Disk" begin
			@testset "Basic" begin
				mktempdir() do dir
					let cache = Cache(CacheKey, Deduplicator(); dir)
						key = create_test_key(cache, "basic")
						r = cache_get!(()->key2result(key), cache, key; use_disk=true)
						@test r == ["basic"]
						@test compute_called!()

						r2 = cache_get!(()->key2result(key), cache, key; use_disk=true)
						@test r2 == ["basic"]
						@test r2 === r
						@test !compute_called!()

						# Test that it works with a newly deduplicated key too
						key = create_test_key(cache, "basic")
						r3 = cache_get!(()->key2result(key), cache, key; use_disk=true)
						@test r3 == ["basic"]
						@test r3 === r
						@test !compute_called!()
					end

					# Check files on disk
					@test only(readdir(dir)) == "6e681ecf52c01af107c571f24b6bf6e87f1fd65afec73f23be37dae3d0430540.jld2"

					let cache = Cache(CacheKey, Deduplicator(); dir) # recreate cache - but keep cache data on disk
						key = create_test_key(cache, "basic")
						r = cache_get!(()->key2result(key), cache, key; use_disk=true)
						@test r == ["basic"]
						@test !compute_called!()
					end
				end
			end

			@testset "GC key" begin
				mktempdir() do dir
					cache = Cache(CacheKey, Deduplicator(); dir)

					put_old_key!(cache; use_disk=true)
					@test compute_called!()
					@test isempty(cache.mem)

					key = create_test_key(cache, "GC")

					r = cache_get!(()->key2result(key), cache, key; use_disk=true)
					@test r == ["GC"]
					@test !compute_called!()
				end
			end

			@testset "GC result" begin
				mktempdir() do dir
					cache = Cache(CacheKey, Deduplicator(); dir)

					key = create_test_key(cache, "GC")

					put_old_result!(cache, key; use_disk=true)
					@test compute_called!()
					@test only(values(cache.mem)).value === nothing # Test that result WeakRef has been GCed

					r = cache_get!(()->key2result(key), cache, key; use_disk=true)
					@test r == ["GC"]
					@test !compute_called!()
				end
			end
		end


		@testset "Storage" begin
			# mktempdir() do dir
			let dir = mktempdir() # Cleanup when Julia process exits - useful for inkeyting
				error_fun = ()->error("This should not have been called.")

				@testset "Simple" begin
					@testset "Vector" begin
						x = [1,5,2]
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa ROVec{Int}
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							@test read(h5, "root") == x

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					@testset "Matrix" begin
						x = [1 5; 2 1]
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa ROMat{Int}
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							@test read(h5, "root") == x

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					@testset "3D Array" begin
						x = [1 5; 2 1;;; 2 4; 0 1]
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa ROArray{Int,3}
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							@test read(h5, "root") == x

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					@testset "Tuple" begin
						x = (1,5,2)
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Tuple"
							@test read(root, "length") == 3
							@test read(root, "1") == 1
							@test read(root, "2") == 5
							@test read(root, "3") == 2

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					@testset "NamedTuple" begin
						x = (; c=1, b=5, a=2)
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "NamedTuple"
							@test read(root, "keys") == (; var"1"="c", var"2"="b", var"3"="a")
							@test read(root, "1") == 1
							@test read(root, "2") == 5
							@test read(root, "3") == 2

							types, custom = extract_jld2_types(h5)
							@test _fuzzy_pop!(types, r"(^|\.)Tuple")
							@test _fuzzy_pop!(types, "Symbol")
							@test types == []
							@test custom == []
						end
					end

					@testset "Pair" begin
						x = "a"=>2
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Pair"
							@test read(root, "length") == 2
							@test read(root, "1") == "a"
							@test read(root, "2") == 2

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					@testset "Dict" begin
						x = Dict("a"=>2, "b"=>3)
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Dict"
							keys = read(root, "keys")
							values = read(root, "values")
							@test Dict(keys.=>values) == x

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					@testset "Set" begin
						x = Set((1,5,2))
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Set"
							@test read(root, "length") == 1
							g = root["1"]
							keys = read(g, "keys")
							@test isempty(g["values"]) # just nothings, so it takes no space
							@test Set(keys) == x

							types, custom = extract_jld2_types(h5)
							@test _fuzzy_pop!(types, "Nothing") # for values of wrapped Dict
							@test types == []
							@test custom == []
						end
					end

					@testset "$str" for (x,str) in ((iszero,"iszero"), (only,"only"), (!=,"!="))
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 === x
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 === x

						h5open(key2path(cache, key), "r") do h5
							@test read(h5, "root") == str

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, str=>"String")
							@test custom == []
						end

					end
				end

				@testset "BitVector" begin
					x = sin.((1:79).^2) .< 0 # just to make some bit pattern
					cache = Cache(CacheKey, Deduplicator(); dir)
					key = new_key(cache)
					x2 = cache_get!(Returns(x), cache, key; use_disk=true)
					@test x2 == x
					@test deduplicate!(cache.deduplicator, x2) === x2
					empty!(cache.mem) # force loading from disk
					x3 = cache_get!(error_fun, cache, key; use_disk=true)
					@test x3 == x
					@test x3 isa ROBitVec
					@test deduplicate!(cache.deduplicator, x3) === x3

					h5open(key2path(cache, key), "r") do h5
						# We already test the ability to read back the contents using JLD2, so no need to test the values here.

						types, custom = extract_jld2_types(h5)
						@test _fuzzy_pop!(types, "BitArray")
						@test _fuzzy_pop!(types, "Tuple")
						@test types == []
						@test custom == []
					end
				end
				@testset "BitMatrix" begin
					x = falses(17,23)
					x[:] .= sin.((1:length(x)).^2) .< 0 # just to make some bit pattern
					cache = Cache(CacheKey, Deduplicator(); dir)
					key = new_key(cache)
					x2 = cache_get!(Returns(x), cache, key; use_disk=true)
					@test x2 == x
					@test deduplicate!(cache.deduplicator, x2) === x2
					empty!(cache.mem) # force loading from disk
					x3 = cache_get!(error_fun, cache, key; use_disk=true)
					@test x3 == x
					@test x3 isa ROBitMat
					@test deduplicate!(cache.deduplicator, x3) === x3

					h5open(key2path(cache, key), "r") do h5
						# We already test the ability to read back the contents using JLD2, so no need to test the values here.

						types, custom = extract_jld2_types(h5)
						@test _fuzzy_pop!(types, "BitArray")
						@test _fuzzy_pop!(types, "Tuple")
						@test types == []
						@test custom == []
					end
				end

				@testset "Ranges" begin
					@testset "$x" for x in (1:100, 0:3:100, 0:3.0:100, LinRange(-0.1,0.3,5), 'R':'Y', 'Y':-1:'R')
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						# Test that the value was properly written using CustomStorage
						h5open(key2path(cache, key), "r") do h5
							# We already test the ability to read back the contents using JLD2, so no need to test the values here.

							types, custom = extract_jld2_types(h5)
							typeof(x) <: UnitRange && _fuzzy_pop!(types, "UnitRange")
							typeof(x) <: StepRange && _fuzzy_pop!(types, r"StepRange$")
							typeof(x) <: StepRangeLen && _fuzzy_pop!(types, r"StepRangeLen$")
							typeof(x) <: StepRangeLen && _fuzzy_pop!(types, "TwicePrecision")
							typeof(x) <: LinRange && _fuzzy_pop!(types, "LinRange")
							eltype(x) == Char && _fuzzy_pop!(types, "Char")
							@test types == []
							@test custom == []
						end
					end
				end

				@testset "Regex" begin
					@testset "$(repr(x))" for x in (r"text",)# r"^a\d+[^_]", r"text"i, r"text"m, r"text"s, r"text"x, r"text"a)
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						# Test that the value was properly written using CustomStorage
						h5open(key2path(cache, key), "r") do h5
							root = read(h5, "root")
							@test root == repr(x)

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, "Regex"=>"String")
							@test custom == []
						end
					end
				end

				@testset "VersionNumber" begin
					@testset "$x" for x in (v"1.0.0", v"1.2.3-alpha1", v"0.0.1-rc1+456")
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2 == x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3 == x
						@test x3 isa typeof(x)
						@test deduplicate!(cache.deduplicator, x3) === x3

						# Test that the value was properly written using CustomStorage
						h5open(key2path(cache, key), "r") do h5
							root = read(h5, "root")
							@test root == string(x)

							types, custom = extract_jld2_types(h5)
							@test _fuzzy_pop!(types, "VersionNumber") # WHY IS THIS NEEDED? Seems like an issue in JLD2.
							@test types == []
							@test _fuzzy_pop!(custom, "VersionNumber"=>"String")
							@test custom == []
						end
					end
				end

				@testset "Nested Vector" begin
					x = [[1,5,2], [4,4,2]]
					cache = Cache(CacheKey, Deduplicator(); dir)
					key = new_key(cache)
					x2 = cache_get!(Returns(x), cache, key; use_disk=true)
					@test x2 == x
					@test deduplicate!(cache.deduplicator, x2) === x2
					empty!(cache.mem) # force loading from disk
					x3 = cache_get!(error_fun, cache, key; use_disk=true)
					@test x3 == x
					@test x3 isa ROVec{ROVec{Int}}
					@test deduplicate!(cache.deduplicator, x3) === x3

					# Test that the value was properly written using Groups and CustomStorage
					h5open(key2path(cache, key), "r") do h5
						root = h5["root"]
						@test read(root, "type") == "Array"
						@test read(root, "1") == [1,5,2]
						@test read(root, "2") == [4,4,2]

						types, custom = extract_jld2_types(h5)
						@test _fuzzy_pop!(types, "Tuple")
						@test types == []
						@test custom == []
					end
				end

				@testset "SparseMatrixCSC" begin
					x = sparse([2,5,3], [1,1,8], [5.0,4.0,3.1], 20, 10)
					cache = Cache(CacheKey, Deduplicator(); dir)
					key = new_key(cache)
					x2 = cache_get!(Returns(x), cache, key; use_disk=true)
					@test x2 == x
					@test deduplicate!(cache.deduplicator, x2) === x2
					empty!(cache.mem) # force loading from disk
					x3 = cache_get!(error_fun, cache, key; use_disk=true)
					@test x3 == x
					@test x3 isa typeof(x)
					@test deduplicate!(cache.deduplicator, x3) === x3

					# Test that the value was properly written using Groups and CustomStorage
					h5open(key2path(cache, key), "r") do h5
						root = h5["root"]
						@test read(root, "type") == "SparseMatrixCSC"
						@test read(root, "length") == 5
						@test read(root, "1") == 20
						@test read(root, "2") == 10
						@test read(root, "3") == x.colptr
						@test read(root, "4") == x.rowval
						@test read(root, "5") == x.nzval

						types, custom = extract_jld2_types(h5)
						@test types == []
						@test custom == []
					end
				end

				@testset "SparseVector" begin
					x = sparsevec([2,5,3], [5.0,4.0,3.1], 20)
					cache = Cache(CacheKey, Deduplicator(); dir)
					key = new_key(cache)
					x2 = cache_get!(Returns(x), cache, key; use_disk=true)
					@test x2 == x
					@test deduplicate!(cache.deduplicator, x2) === x2
					empty!(cache.mem) # force loading from disk
					x3 = cache_get!(error_fun, cache, key; use_disk=true)
					@test x3 == x
					@test x3 isa typeof(x)
					@test deduplicate!(cache.deduplicator, x3) === x3

					h5open(key2path(cache, key), "r") do h5
						root = h5["root"]
						@test read(root, "type") == "SparseVector"
						@test read(root, "length") == 3
						@test read(root, "1") == 20
						@test read(root, "2") == x.nzind
						@test read(root, "3") == x.nzval

						types, custom = extract_jld2_types(h5)
						@test types == []
						@test custom == []
					end
				end

				@testset "DataFrame" begin
					x = DataFrame(a=[1,5], b=[r"abc", r"def"])
					cache = Cache(CacheKey, Deduplicator(); dir)
					key = new_key(cache)
					x2 = cache_get!(Returns(x), cache, key; use_disk=true)
					@test x2 == x
					@test deduplicate!(cache.deduplicator, x2) === x2
					empty!(cache.mem) # force loading from disk
					x3 = cache_get!(error_fun, cache, key; use_disk=true)
					@test x3 == x
					@test x3 isa DataFrame
					@test deduplicate!(cache.deduplicator, x3) === x3

					# Test that the value was properly written using Groups and CustomStorage
					h5open(key2path(cache, key), "r") do h5
						root = h5["root"]
						@test read(root["type"]) == "DataFrame"
						@test read(root["names"]) == ["a", "b"]
						@test read(root["1"]) == [1,5]
						# @test read(root["2"]) == ["r\"abc\"", "r\"def\""]
						@test read(root["2"], "type") == "Array"
						@test read(root["2"], "size") == (; var"1"=2,)
						@test read(root["2"], "1") == "r\"abc\""
						@test read(root["2"], "2") == "r\"def\""

						types, custom = extract_jld2_types(h5)
						@test _fuzzy_pop!(types, r"(^|\.)Tuple") # Used for non-inlined array size
						@test types == []
						@test _fuzzy_pop!(custom, "Regex"=>"String")
						@test custom == []
					end
				end


				# @testset "Inconcrete pairs" begin
				# 	# x = [2=>3, 5=>[r"a"]]
				# 	# x = (2=>3, 5=>[r"a"])
				# 	# x = (; a=Pair{Int,Any}(5, [r"a"]))
				# 	# x = Pair{Int,Any}(5, r"a")
				# 	cache = Cache(CacheKey, Deduplicator(); dir)
				# 	key = new_key(cache)
				# 	x2 = cache_get!(Returns(x), cache, key; use_disk=true)
				# 	@test x2 == x
				# 	@test deduplicate!(cache.deduplicator, x2) === x2
				# 	empty!(cache.mem) # force loading from disk
				# 	x3 = cache_get!(error_fun, cache, key; use_disk=true)
				# 	@test x3 == x
				# 	@show typeof(x3)
				# 	# @test x3 isa ROVec{Pair{Int,Any}}
				# 	@test deduplicate!(cache.deduplicator, x3) === x3

				# 	# Test that the value was properly written using Groups and CustomStorage
				# 	h5open(key2path(cache, key), "r") do h5
				# 		root = h5["root"]
				# 		@show root
				# 		# read(h5, "root")
				# 		# @show read(root, "type")
				# 	end
				# end


				@testset "Returns" begin
					let x = Returns([1,5,2])
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2.value == x.value
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3.value == x.value
						@test x3 isa Returns
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Returns"
							@test read(root, "length") == 1
							@test read(root, "1") == [1,5,2]

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end

					let x = Returns(r"abc")
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2.value == x.value
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3.value == x.value
						@test x3 isa Returns
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Returns"
							@test read(root, "length") == 1
							@test read(root, "1") == repr(x.value)

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, "Regex"=>"String")
							@test custom == []
						end
					end
				end

				@testset "Fix" begin
					let x = in([1,5,2])
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2.f === x.f
						@test x2.x == x.x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3.f === x.f
						@test x3.x == x.x
						@test x3 isa Base.Fix2
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Fix"
							@test read(root, "length") == 3
							@test read(root, "1") == 2
							@test read(root, "2") == "in"
							@test read(root, "3") == [1,5,2]

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, "in"=>"String")
							@test custom == []
						end
					end

					let x = startswith(r"abc")
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2.f === x.f
						@test x2.x == x.x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3.f === x.f
						@test x3.x == x.x
						@test x3 isa Base.Fix2
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "Fix"
							@test read(root, "length") == 3
							@test read(root, "1") == 2
							@test read(root, "2") == "startswith"
							@test read(root, "3") == repr(x.x)

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, "startswith"=>"String")
							@test _fuzzy_pop!(custom, "Regex"=>"String")
							@test custom == []
						end
					end
				end

				@testset "ComposedFunction" begin
					let x = !isequal([1,5,2])
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2.outer === x.outer
						@test x2.inner.f === x.inner.f
						@test x2.inner.x == x.inner.x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3.outer === x.outer
						@test x3.inner.f === x.inner.f
						@test x3.inner.x == x.inner.x
						@test x3 isa ComposedFunction
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "ComposedFunction"
							@test read(root, "length") == 2
							@test read(root, "1") == "!"
							@test read(root["2"], "type") == "Fix"

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, "!"=>"String")
							@test _fuzzy_pop!(custom, "isequal"=>"String")
							@test custom == []
						end
					end

					let x = !startswith(r"abc")
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test x2.outer === x.outer
						@test x2.inner.f === x.inner.f
						@test x2.inner.x == x.inner.x
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test x3.outer === x.outer
						@test x3.inner.f === x.inner.f
						@test x3.inner.x == x.inner.x
						@test x3 isa ComposedFunction
						@test deduplicate!(cache.deduplicator, x3) === x3

						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "ComposedFunction"
							@test read(root, "length") == 2
							@test read(root, "1") == "!"
							@test read(root["2"], "type") == "Fix"

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test _fuzzy_pop!(custom, "!"=>"String")
							@test _fuzzy_pop!(custom, "startswith"=>"String")
							@test _fuzzy_pop!(custom, "Regex"=>"String")
							@test custom == []
						end
					end
				end

				@testset "Inlined eltypes" begin
					@testset "$T" for (f,T) in ((a->[a...], ROVec),
					                            (a->Dict(1:length(a) .=> a), Dict{Int}), # test values
					                            (a->Dict(a .=> 1:length(a)), Dict{K,Int} where K), # test keys 
					                           )
						@testset "$E" for (elements,E) in ( ((1,nothing,5), Union{Int,Nothing}),
							                                ((1,missing,5), Union{Int,Missing}),
							                                ((1=>false,5=>true), Pair{Int,Bool}),
							                                (((1,5.0),(8,7.0)), Tuple{Int,Float64}),
							                                (((;v=1,u=5.0),(;v=8,u=7.0)), @NamedTuple{v::Int,u::Float64}),
							                                # ((Returns(1),Returns(5)), Returns{Int}), # ACTUALLY I DON'T WANT THIS TO INLINE, FIX!
							                                (((1,2)=>(3=>4),(5,6)=>(7=>8)), Pair{Tuple{Int,Int},Pair{Int,Int}}), # some nesting
							                                (("a","b"), String),
							                                ((:a,:b), Symbol),
							                                (('a','b'), Char),
						                                  )
							if Nothing <: E && T == Dict{K,Int} where K
								continue # We do not support nothing as a Key in Dicts because it cannot be naturally compared with isless (which is need for hashing currently)
							end

							x = f(elements)
							cache = Cache(CacheKey, Deduplicator(); dir)
							key = new_key(cache)
							x2 = cache_get!(Returns(x), cache, key; use_disk=true)
							@test isequal(x2, x)
							@test deduplicate!(cache.deduplicator, x2) === x2
							empty!(cache.mem) # force loading from disk
							x3 = cache_get!(error_fun, cache, key; use_disk=true)
							@test isequal(x3, x)
							@test x3 isa T{E}
							@test deduplicate!(cache.deduplicator, x3) === x3

							h5open(key2path(cache, key), "r") do h5
								root = h5["root"]

								if T <: ROVec
									@test root isa HDF5.Dataset # We rely on JLD2 handling, so no need to test the value here
								elseif T <: Dict{Int}
									@test read(root, "type") == "Dict"
									@test sort(read(root, "keys")) == 1:length(x)
									@test root["values"] isa HDF5.Dataset # We rely on JLD2 handling, so no need to test the value here
								elseif T <: Dict{K,Int} where K
									@test read(root, "type") == "Dict"
									@test root["keys"] isa HDF5.Dataset # We rely on JLD2 handling, so no need to test the value here
									@test sort(read(root, "values")) == 1:length(x)
								end

								types, custom = extract_jld2_types(h5)
								E isa Union && @test _fuzzy_pop!(types, "JLD2.InlineUnionEl")
								Nothing <: E && @test _fuzzy_pop!(types, "Nothing")
								Missing <: E && @test _fuzzy_pop!(types, "Missing")
								E <: Pair && @test _fuzzy_pop!(types, "Pair")
								E <: Tuple && @test _fuzzy_pop!(types, r"(^|\.)Tuple")
								if E <: NamedTuple
									@test _fuzzy_pop!(types, "NamedTuple")
									# We don't care that much JLD2 stores the NamedTuple, so no @test for these:
									_fuzzy_pop!(types, "Symbol")
									_fuzzy_pop!(types, "NTuple")
									_fuzzy_pop!(types, r"(^|\.)Tuple")
								end
								# E <: Returns && @test _fuzzy_pop!(types, "Returns")
								if E <: Pair{<:Tuple, <:Pair}
									# We don't care that much JLD2 stores the Pair, so no @test for these:
									_fuzzy_pop!(types, "NTuple")
								end
								E === Symbol && @test _fuzzy_pop!(types, "Symbol")
								E === Char && @test _fuzzy_pop!(types, "Char")
								@test types == []
								@test custom == []
							end
						end
					end
				end


				@testset "Non-inlined eltypes" begin
					@testset "$T" for (f,T) in ((a->[a...], ROVec),
					                            (a->Dict(1:length(a) .=> a), Dict{Int}), # test values
					                            (a->Dict(a .=> 1:length(a)), Dict{K,Int} where K), # test keys - are there any Key types we can test this with?
					                           )
						@testset "$E" for (elements,E) in ( ((Returns(1), Returns(5)), Returns{Int}),
							                                ((1=>"a",5=>"b"), Pair{Int,String}),
							                                ((:a=>1,:b=>5), Pair{Symbol,Int}),
							                                ((('a',"A"),('b',"B")), Tuple{Char,String}),
						                                  )
							if E <: Returns && T == Dict{K,Int} where K
								continue # We do not support Returns as a Key in Dicts because it cannot be naturally compared with isless (which is need for hashing currently)
							end

							x = f(elements)
							cache = Cache(CacheKey, Deduplicator(); dir)
							key = new_key(cache)
							x2 = cache_get!(Returns(x), cache, key; use_disk=true)
							@test x2 == x
							@test deduplicate!(cache.deduplicator, x2) === x2
							empty!(cache.mem) # force loading from disk
							x3 = cache_get!(error_fun, cache, key; use_disk=true)
							@test x3 == x
							@test x3 isa T{E}
							@test deduplicate!(cache.deduplicator, x3) === x3

							h5open(key2path(cache, key), "r") do h5
								root = h5["root"]
								if T <: ROArray
									g = root
								elseif T <: Dict{Int}
									@test read(root, "type") == "Dict"
									g = root["values"]
								elseif T <: Dict{<:Any,Int}
									@test read(root, "type") == "Dict"
									g = root["keys"]
								else
									error("Unhandled case.")
								end
								@test read(g, "type") == "Array"
								@test read(g, "size") == (; var"1"=length(elements),)

								types, custom = extract_jld2_types(h5)
								@test _fuzzy_pop!(types, r"(^|\.)Tuple") # used for Array size
								E <: Pair{Symbol} && @test _fuzzy_pop!(types, "Symbol")
								E <: Tuple{Char,<:Any} && @test _fuzzy_pop!(types, "Char")
								@test types == []
								@test custom == []
							end
						end
					end
				end


				# TODO: Test with Dict/Set too?
				@testset "Complicated eltype" begin
					v = [1,5,2]
					values = ((v,v), v=>v, Dict(v=>v), missing, nothing, true, 0.3, r"abc", v"0.1.0", 1=>r"bcd", r"cde"=>2)

					@testset "$T" for (f,T) in ((a->[a...], ROVec{Any}),
					                            (identity, Tuple),
					                            (a->NamedTuple(Symbol.(string.("s",1:length(a))) .=> a), NamedTuple),
					                           )
						x = f(values)
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)
						x2 = cache_get!(Returns(x), cache, key; use_disk=true)
						@test isequal(x2, x)
						@test deduplicate!(cache.deduplicator, x2) === x2
						empty!(cache.mem) # force loading from disk
						x3 = cache_get!(error_fun, cache, key; use_disk=true)
						@test isequal(x3, x)
						@test x3 isa T
						@test deduplicate!(cache.deduplicator, x3) === x3

						# Test that the value was properly written using Groups and CustomStorage
						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root["1"], "type") == "Tuple"
							@test read(root["2"], "type") == "Pair"
							@test read(root["3"], "type") == "Dict"
							@test size(root["4"]) == () # missing
							@test size(root["5"]) == () # nothing
							@test read(root["6"]) == true
							@test read(root["7"]) == 0.3
							@test read(root["8"]) == "r\"abc\""
							@test read(root["9"]) == "0.1.0"
							@test read(root["10"], "type") == "Pair"
							@test read(root["11"], "type") == "Pair"

							types, custom = extract_jld2_types(h5)
							@test _fuzzy_pop!(types, "Tuple")
							@test _fuzzy_pop!(types, "Missing")
							@test _fuzzy_pop!(types, "Nothing")
							@test _fuzzy_pop!(types, "VersionNumber")
							@test T !== NamedTuple || _fuzzy_pop!(types, "Symbol")
							@test types == []
							@test _fuzzy_pop!(custom, "Regex"=>"String")
							@test _fuzzy_pop!(custom, "VersionNumber"=>"String")
							@test custom == []
						end
					end
				end

				# TODO: Test storage with more different Pairs as eltypes?

				# TODO: More?

				@testset "CompoundResult" begin
					let u = [1,5,2], v = [0,10,20], w = (v,"A")
						x = CompoundResult(; sub=u, sub2=w)
						cache = Cache(CacheKey, Deduplicator(); dir)
						key = new_key(cache)

						u2 = cache_get_subresult!(Returns(x), cache, key; sub="sub", use_disk=true)
						@test u2 == u
						@test deduplicate!(cache.deduplicator, u2) === u2

						w2 = cache_get_subresult!(error_fun, cache, key; sub="sub2", use_disk=true) # already computed, get from in-mem cache
						@test w2 == w
						@test deduplicate!(cache.deduplicator, w2) === w2

						# --- Fake GC of subresults ---
						cr = only(values(cache.mem))

						@test cr.values[1].value === parent(u2)
						cr.values[1] = WeakRef() # Remove ref to u
						u3 = cache_get_subresult!(error_fun, cache, key; sub="sub", use_disk=true)
						@test u3 == u
						@test u3 isa ROVec{Int}
						@test deduplicate!(cache.deduplicator, u3) === u3

						# Remove ref to v
						cr.values[2] = DeconstructedWeak(_reconstructed_type(cr.values[2]), (WeakRef(), w2[2])) # Can we write this more cleanly?
						w3 = cache_get_subresult!(error_fun, cache, key; sub="sub2", use_disk=true)
						@test w3 == w
						@test w3 isa Tuple{ROVec{Int}, String}
						@test deduplicate!(cache.deduplicator, w3) === w3

						# --- Empty in-mem cache, i.e. mimic that the result was computed in a previous session ---
						empty!(cache.mem)

						u4 = cache_get_subresult!(error_fun, cache, key; sub="sub", use_disk=true)
						@test u4 == u
						@test u4 isa ROVec{Int}
						@test deduplicate!(cache.deduplicator, u4) === u4

						w4 = cache_get_subresult!(error_fun, cache, key; sub="sub2", use_disk=true)
						@test w4 == w
						@test w4 isa Tuple{ROVec{Int}, String}
						@test deduplicate!(cache.deduplicator, w4) === w4


						# --- Fake GC of subresults after loading from disk ---
						cr = only(values(cache.mem))

						@test cr.values[1].value === parent(u4)
						cr.values[1] = WeakRef() # Remove ref to u
						u5 = cache_get_subresult!(error_fun, cache, key; sub="sub", use_disk=true)
						@test u5 == u
						@test u5 isa ROVec{Int}
						@test deduplicate!(cache.deduplicator, u5) === u5

						# Remove ref to v
						cr.values[2] = DeconstructedWeak(_reconstructed_type(cr.values[2]), (WeakRef(), w4[2])) # Can we write this more cleanly?
						w5 = cache_get_subresult!(error_fun, cache, key; sub="sub2", use_disk=true)
						@test w5 == w
						@test w5 isa Tuple{ROVec{Int}, String}
						@test deduplicate!(cache.deduplicator, w5) === w5


						h5open(key2path(cache, key), "r") do h5
							root = h5["root"]
							@test read(root, "type") == "CompoundResult"
							@test read(root, "keys") == ["sub", "sub2"]

							@test read(root, "1") == u

							@test read(root["2"], "type") == "Tuple"
							@test read(root["2"], "length") == 2
							@test read(root["2"], "1") == v
							@test read(root["2"], "2") == "A"

							types, custom = extract_jld2_types(h5)
							@test types == []
							@test custom == []
						end
					end
				end

			end
		end
	end
end
