using Test
using ReproducibleJobs
using ReproducibleJobs.Deduplicators
using ReproducibleJobs.Deduplicators: ROArray, ROVec, ROMat, ROBitArray, ROBitVec, ROBitMat, Hash, deduplication_hash, lookup_hash, deduplicate_type, deduplication_pointer, CompoundResult
using ReadOnlyArrays
using StableHashTraits
using SparseArrays
using DataFrames

reporter_was_called::Bool = false

struct Reporter
	expected_transfer_ownership::Bool
end
Deduplicators.deduplicate_type(::Type{Reporter}) = true
function Deduplicators.deduplicate_children!(d, r::Reporter; transfer_ownership)
	@test transfer_ownership == r.expected_transfer_ownership
	global reporter_was_called = true
	r
end
function Deduplicators.deduplication_hash(d, r::Reporter)
	Hash((UInt64(1),UInt64(2),UInt64(3),UInt64(4))) # dummy
end


function put_old_weakref!(d::Deduplicator)
	x = parent(deduplicate!(d, [9,5,2]))
	h = lookup_hash(d, x)
	@assert h !== nothing
	p = deduplication_pointer(x)
	@assert p !== nothing
	d.pointer2obj[p] = (WeakRef(), h)
	d.hash2obj[h] = WeakRef()
	d
end


function run_deduplicator_tests()
	@testset "Simple types" begin
		d = Deduplicator()

		for x in (true, false, 2, 3.4, "hello", :hello, 'C', v"1.0.0", v"0.1.2-alpha.1", Float64, DataFrame, :, nothing, missing)
			@test @inferred(deduplicate!(d, x)) === x
		end
		@test isempty(d.pointer2obj)
		@test isempty(d.hash2obj)

		for x in (identity, !, iszero, ismissing, isequal, startswith, only, in, <, <=, >, >=, ==, !=)
			@test @inferred(deduplicate!(d, x)) === x
		end
		@test isempty(d.pointer2obj)
		@test isempty(d.hash2obj)
	end

	@testset "Basic" begin
		@testset "Vector" begin
			d = Deduplicator()
			let x = [1,5,2]
				x2 = @inferred deduplicate!(d, x)
				@test x2 == x
				@test x2 isa ROVec{Int}
				@test parent(x2) !== x

				@test @inferred(deduplicate!(d, x)) === x2
				@test @inferred(deduplicate!(d, x2)) === x2
			end
			let x = [r"a", r"b"i]
				x2 = @inferred deduplicate!(d, x)
				@test x2 == x
				@test x2 isa ROVec{Regex}
				@test parent(x2) !== x

				@test @inferred(deduplicate!(d, x)) === x2
				@test @inferred(deduplicate!(d, x2)) === x2
			end
			let x = [v"0.1.0", v"1.2.3-alpha1"]
				x2 = @inferred deduplicate!(d, x)
				@test x2 == x
				@test x2 isa ROVec{VersionNumber}
				@test parent(x2) !== x

				@test @inferred(deduplicate!(d, x)) === x2
				@test @inferred(deduplicate!(d, x2)) === x2
			end
		end
		@testset "Matrix" begin
			d = Deduplicator()
			x = [1 5; 2 1]
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROMat{Int}
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
		@testset "3D Array" begin
			d = Deduplicator()
			x = [1 5; 2 1;;; 2 4; 0 1]
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROArray{Int,3}
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end

		@testset "Tuple" begin
			d = Deduplicator()
			x = (1,5,2)
			x2 = @inferred deduplicate!(d, x)
			@test x === x2

			y = ([8,2,4], [4,2])
			y2 = @inferred deduplicate!(d, y)

			@test y2 == y
			@test y2 isa NTuple{2,ROVec{Int}}
			@test parent(y2[1]) !== y[1]

			@test @inferred(deduplicate!(d, y)) === y2
			@test @inferred(deduplicate!(d, y2)) === y2
		end

		@testset "NamedTuple" begin
			d = Deduplicator()
			x = (;a=1, b=5, c=2)
			x2 = @inferred deduplicate!(d, x)
			@test x === x2

			y = (; v=[8,2,4], u=[4,2])
			y2 = @inferred deduplicate!(d, y)

			@test y2 == y
			@test y2 isa @NamedTuple{v::ROVec{Int64}, u::ROVec{Int64}}
			@test parent(y2.v) !== y.v

			@test @inferred(deduplicate!(d, y)) === y2
			@test @inferred(deduplicate!(d, y2)) == y2
		end

		@testset "Pair" begin
			d = Deduplicator()
			x = ("a"=>2)
			x2 = @inferred deduplicate!(d, x)
			@test x === x2

			let y = "b"=>[2,8]
				y2 = @inferred deduplicate!(d, y)

				@test y2 == y
				@test y2 isa Pair{String,ROVec{Int}}
				@test parent(y2.second) !== y.second

				@test @inferred(deduplicate!(d, y)) === y2
				@test @inferred(deduplicate!(d, y2)) === y2
			end
			let y = [3,0]=>"A"
				y2 = @inferred deduplicate!(d, y)

				@test y2 == y
				@test y2 isa Pair{ROVec{Int}, String}
				@test parent(y2.first) !== y.first

				@test @inferred(deduplicate!(d, y)) === y2
				@test @inferred(deduplicate!(d, y2)) === y2
			end
			let y = [2,1]=>[5,4]
				y2 = @inferred deduplicate!(d, y)

				@test y2 == y
				@test y2 isa Pair{ROVec{Int}, ROVec{Int}}
				@test parent(y2.first) !== y.first

				@test @inferred(deduplicate!(d, y)) === y2
				@test @inferred(deduplicate!(d, y2)) === y2
			end
		end

		@testset "Ranges" begin
			d = Deduplicator()
			let x = 1:10 # UnitRange
				x2 = @inferred deduplicate!(d, x)
				@test x === x2
			end
			let x = 1:3:10 # StepRange
				x2 = @inferred deduplicate!(d, x)
				@test x === x2
			end
			let x = 1:3.0:10 # StepRangeLen
				x2 = @inferred deduplicate!(d, x)
				@test x === x2
			end
			let x = 'C':'X'
				x2 = @inferred deduplicate!(d, x)
				@test x === x2
			end
			let x = 'X':-1:'C'
				x2 = @inferred deduplicate!(d, x)
				@test x === x2
			end
			let x = LinRange(-0.1,0.3,5)
				x2 = @inferred deduplicate!(d, x)
				@test x === x2
			end
		end

		@testset "Returns" begin
			d = Deduplicator()
			x = Returns(true)
			x2 = @inferred deduplicate!(d, x)
			@test x2 === x
			@test isempty(d.pointer2obj)

			y = Returns([1,5,2])
			y2 = @inferred deduplicate!(d, y)

			@test y2.value == y.value
			@test y2.value !== y.value
			@test y2 isa Returns{ROVec{Int}}

			@test @inferred(deduplicate!(d, y)) === y2
			@test @inferred(deduplicate!(d, y2)) === y2
		end

		@testset "Fix" begin
			d = Deduplicator()
			x = in((1,5,2))
			x2 = @inferred deduplicate!(d, x)
			@test x2 === x
			@test isempty(d.pointer2obj)

			y = in([1,5,2])
			y2 = @inferred deduplicate!(d, y)

			@test y2.f == y.f
			@test y2.x == y.x
			@test y2.x !== y.x
			@test y2 isa Base.Fix2{typeof(in), ROVec{Int}}

			@test @inferred(deduplicate!(d, y)) === y2
			@test @inferred(deduplicate!(d, y2)) === y2
		end

		@testset "ComposedFunction" begin
			d = Deduplicator()
			x = !ismissing
			x2 = @inferred deduplicate!(d, x)
			@test x2 === x
			@test isempty(d.pointer2obj)

			# TODO: Fix and re-enable @inferred below
			#       The involved types get too complicated so type inference gives up. Maybe we can refactor to make it easier?

			y = !isequal([1,5,2])
			# y2 = @inferred deduplicate!(d, y)
			y2 = deduplicate!(d, y)

			@test y2.outer === y.outer
			@test y2.inner.f === y.inner.f
			@test y2.inner.x == y.inner.x
			@test y2.inner.x !== y.inner.x
			@test y2 isa ComposedFunction{typeof(!), Base.Fix2{typeof(isequal), ROVec{Int}}}

			@test deduplicate!(d, y) === y2
			@test deduplicate!(d, y2) === y2
			# @test @inferred(deduplicate!(d, y)) === y2
			# @test @inferred(deduplicate!(d, y2)) === y2
		end

		@testset "SparseMatrixCSC" begin
			d = Deduplicator()
			x = sparse([2,5,3], [1,1,8], [5.0,4.0,3.1], 20, 10)
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa SparseMatrixCSC{Float64,Int}

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test !isempty(d.pointer2obj)
		end

		@testset "SparseVector" begin
			d = Deduplicator()
			x = sparsevec([2,5,3], [5.0,4.0,3.1], 20)
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa SparseVector{Float64,Int}

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test !isempty(d.pointer2obj)
		end

		@testset "DataFrame" begin
			d = Deduplicator()
			x = DataFrame(; a=[1,5,2], b=[4,4,3])
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2.a isa ROVec{Int}

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test !isempty(d.pointer2obj)
		end
	end

	@testset "ReadOnlyArray" begin
		d = Deduplicator()
		let x = ReadOnlyVector([1,5,2])
			x2 = @inferred deduplicate!(d, x)
			@test x2 === x
		end

		# If it is already present, we should still deduplicate the ReadOnlyArray
		let x = ReadOnlyVector([1,5,2])
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa ROVec{Int}
		end

		# Test that it narrows eltype
		let x = ReadOnlyVector(Real[1.0, 5.0])
			x2 = @inferred ROVec{<:Real} deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa ROVec{Float64}

			@test @inferred(ROVec{<:Real}, deduplicate!(d, x)) === x2
			@test @inferred(ROVec{<:Real}, deduplicate!(d, x2)) === x2
		end

		# Test that deduplicates nested values
		let x = ReadOnlyVector([[1,5,2], [4,5]])
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa ROVec{ROVec{Int}}

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
	end

	@testset "View" begin
		d = Deduplicator()

		let x = @view([1,4,9,16,25][1:2:5])
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa ROVec{Int}

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, copy(x))) === x2
		end

		let x = [3 1 9; 4 7 6; 2 8 5]
			let y = @view(x[:,1])
				y2 = @inferred deduplicate!(d, y)
				@test y2 == y
				@test y2 !== y
				@test y2 isa ROVec{Int}

				@test @inferred(deduplicate!(d, y)) === y2
				@test @inferred(deduplicate!(d, copy(y))) === y2
			end
			let y = @view(x[1,:])
				y2 = @inferred deduplicate!(d, y)
				@test y2 == y
				@test y2 !== y
				@test y2 isa ROVec{Int}

				@test @inferred(deduplicate!(d, y)) === y2
				@test @inferred(deduplicate!(d, copy(y))) === y2
			end
			let y = @view(x[2:3,:])
				y2 = @inferred deduplicate!(d, y)
				@test y2 == y
				@test y2 !== y
				@test y2 isa ROMat{Int}

				@test @inferred(deduplicate!(d, y)) === y2
				@test @inferred(deduplicate!(d, copy(y))) === y2
			end
		end
	end

	@testset "BitArray" begin
		d = Deduplicator()
		let x = sin.((1:79).^2) .< 0 # just to make some bit pattern
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROBitVec
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test length(d.pointer2obj) == 1
			@test length(d.hash2obj) == 1
		end
		let x = falses(17,23)
			x[:] .= sin.((1:length(x)).^2) .< 0 # just to make some bit pattern
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROBitMat
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
		let x = falses(3,5,7)
			x[:] .= sin.((1:length(x)).^2) .< 0 # just to make some bit pattern
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROBitArray{3}
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
	end

	@testset "Array Canonicalization" begin
		d = Deduplicator()

		@testset "Canonicalize: $(eltype(x))" for x in (Union{Nothing,Int}[1,5,2],
		                                                Real[3,3,1],
		                                                ReadOnlyArray(Union{Nothing,Int}[10,5,2]),
		                                                ReadOnlyArray(Real[3,3,7]),
		                                               )
			E = eltype(x)
			x2 = @inferred ROVec{<:E} deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa ROVec{Int}

			@test @inferred(ROVec{<:E}, deduplicate!(d, x)) === x2
			@test @inferred(ROVec{<:E}, deduplicate!(d, x2)) === x2
		end

		@testset "Keep: $(eltype(x))" for x in ([1,5,nothing,2],
		                                        Real[0.4,3,1],
		                                        ReadOnlyArray([10,5,nothing,2]),
		                                        ReadOnlyArray(Real[0.4,3,7]),
		                       )
			E = eltype(x)
			x2 = @inferred ROVec{E} deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa ROVec{E}
			# TODO: Can we avoid copying the ReadOnlyArrays? (Since the eltype doesn't change.) If we can, we should test with ===.

			@test @inferred(ROVec{E}, deduplicate!(d, x)) === x2
			@test @inferred(ROVec{E}, deduplicate!(d, x2)) === x2
		end
	end

	@testset "Array Canonicalization to BitArray" begin
		d = Deduplicator()
		let x = [true, false, true, true]
			@test x isa Vector{Bool}
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ReadOnlyVector{Bool, BitVector}
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
		let x = Union{Nothing,Bool}[false, false, true, false]
			@test x isa Vector{Union{Nothing,Bool}}
			x2 = deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ReadOnlyVector{Bool, BitVector}
			@test parent(x2) !== x

			@test deduplicate!(d, x) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
	end



	@testset "Dict" begin
		d = Deduplicator()

		@testset "$kt keys, $vt values" for kt in (:simple,:nested), vt in (:simple,:nested)
			keys = kt==:simple ? ("a","b") : (["a"],["b","c"])
			vals = vt==:simple ? (2,3) : ([2,0],[3,0])

			x = Dict((keys.=>vals)...)
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test !isempty(d.pointer2obj)
		end

		@testset "Canonicalization" begin
			let x = Dict{Int,Union{Nothing,ROVec{Int}}}(1=>ReadOnlyVector([1,5,2]))
				DT = Dict{Int,<:Union{Nothing,ROVec{Int}}}
				x2 = @inferred DT deduplicate!(d, x)
				@test x2 == x
				@test x2 !== x
				@test valtype(x2) == ROVec{Int}

				@test @inferred(DT, deduplicate!(d, x)) === x2
				@test @inferred(DT, deduplicate!(d, x2)) === x2
			end
			let x = Dict{Union{Nothing,ROVec{Int}},Int}(ReadOnlyVector([1,5,2])=>1)
				DT = Dict{<:Union{Nothing,ROVec{Int}},Int}
				x2 = @inferred DT deduplicate!(d, x)
				@test x2 == x
				@test x2 !== x
				@test keytype(x2) == ROVec{Int}

				@test @inferred(DT, deduplicate!(d, x)) === x2
				@test @inferred(DT, deduplicate!(d, x2)) === x2
			end
		end
	end

	@testset "Set" begin
		d = Deduplicator()

		@testset "$vt" for vt in (:simple,:nested)
			vals = vt==:simple ? (2,3) : ([2,0],[3,0])

			x = Set(vals)
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test !isempty(d.pointer2obj)
		end

		@testset "Canonicalization" begin
			let x = Set{Union{Nothing,ROVec{Int}}}((ReadOnlyVector([1,5,2]),))
				ST = Set{<:Union{Nothing,ROVec{Int}}}
				x2 = @inferred ST deduplicate!(d, x)
				@test x2 == x
				@test x2 !== x
				@test eltype(x2) == ROVec{Int}

				@test @inferred(ST, deduplicate!(d, x)) === x2
				@test @inferred(ST, deduplicate!(d, x2)) === x2
			end

			let x = Set{Real}((0, 3.5))
				x2 = deduplicate!(d, x)
				@test x2 == x
				@test x2 !== x
				@test typeof(x2) == Set{Real}

				@test deduplicate!(d, x) === x2
				@test deduplicate!(d, x2) === x2
			end
		end
	end

	@testset "WeakRefs" begin
		d = Deduplicator()
		put_old_weakref!(d)
		@test only(d.pointer2obj).second[1].value === nothing # Check that the value has been GCed

		x = ReadOnlyVector([9,5,2])
		x2 = @inferred deduplicate!(d, x)
		@test x === x2
		@test length(d.hash2obj)==1
	end

	@testset "Pointer reuse" begin
		# We use a little trick to make it look like we get pointer reuse:
		# 1. Add some object to deduplicator
		# 2. GC that object
		# 3. Create a new object
		# 4. Hack the deduplicator so it looks like the old entry points to the current pointer!

		@testset "Same hash" begin
			d = Deduplicator()
			put_old_weakref!(d)

			x = ReadOnlyVector([9,5,2])
			p = deduplication_pointer(parent(x))
			let (old_p,tup) = only(d.pointer2obj)
				empty!(d.pointer2obj)
				d.pointer2obj[p] = tup
			end
			x2 = @inferred deduplicate!(d, x)
			@test x === x2

			@test length(d.hash2obj) == 1
		end
		@testset "New hash" begin
			d = Deduplicator()
			put_old_weakref!(d)

			x = ReadOnlyVector([7,5,2])
			p = deduplication_pointer(parent(x))
			let (old_p,tup) = only(d.pointer2obj)
				empty!(d.pointer2obj)
				d.pointer2obj[p] = tup
			end
			x2 = @inferred deduplicate!(d, x)
			@test x === x2

			@test length(d.hash2obj) == 2 # If we add cleanup of old hashes when the WeakRefs are invalid, this might no longer hold
		end
	end


	@testset "Nesting" begin
		d = Deduplicator()
		x = [1,5,2]
		x2 = @inferred deduplicate!(d, x)

		y = [4,2,6]
		y2 = @inferred deduplicate!(d, y)

		z = [3,9,1]
		z2 = [3,9,1]

		a = [(x,x2), (y2,y), (z,z2)]
		a2 = deduplicate!(d, a)
		@test a == a2
		@test a !== a2
		@test eltype(a2) == NTuple{2,ROVec{Int}}
		@test a2[1] === (x2,x2)
		@test a2[2] === (y2,y2)
		@test a2[3] == (z,z2)
		@test a2[3] !== (z,z2)

		@test deduplicate!(d, a) === a2
		@test @inferred(deduplicate!(d, a2)) === a2
	end

	@testset "Complicated eltype" begin
		d = Deduplicator()
		x = [1,5,2]
		x2 = @inferred deduplicate!(d, x)

		y = [4,2,6]
		y2 = @inferred deduplicate!(d, y)

		z = [3,9,1]
		z2 = [3,9,1]

		a = [(x,x2), y2=>y, Dict(z=>z2), Dict(z=>z2), missing, nothing, true, 0.3]
		a2 = deduplicate!(d, a)
		@test isequal(a, a2)
		@test a !== a2
		@test eltype(a2) == Any
		@test a2[1] === (x2,x2)
		@test a2[2] === (y2=>y2)
		@test a2[3] == Dict(z=>z2)
		@test a2[4] === a2[3]

		@test deduplicate!(d, a) === a2
		@test deduplicate!(d, a2) === a2
	end

	@testset "Inconcrete Pairs" begin
		d = Deduplicator()
		x = [2=>3, 4=>"a"]
		@test eltype(x) == Pair{Int, Any}
		@test typeof(x[1]) == Pair{Int, Any} # This is the surprising part, we would have expected it to be Pair{Int,Int}

		x2 = deduplicate!(d, x)
		@test x2 == x
		@test x2 !== x

		@test deduplicate!(d, x) === x2
		@test deduplicate!(d, x2) === x2 # TODO: Can we make this @inferred?
	end

	@testset "Many items" begin
		d = Deduplicator()

		# These tests are not very interesting, can we do something better?
		N = 1_000
		vecs = [deduplicate!(d, fill(i,10)) for i in 1:N] # keep them around
		@test length(d.pointer2obj) == N
		@test length(d.hash2obj) == N

		vecs2 = [deduplicate!(d, fill(i,10)) for i in 1:N] # keep them around
		@test length(d.pointer2obj) == N
		@test length(d.hash2obj) == N

		@test vecs == vecs2 # use them so they are not GCed too early
	end

	@testset "transfer_ownership" begin
		d = Deduplicator()

		let x = [1,5,2]
			x2 = @inferred deduplicate!(d, x; transfer_ownership=true)
			@test x2 isa ROVec{Int}
			@test parent(x2) === x
		end

		let x = ReadOnlyVector([10,5,2])
			# TODO: Fix this case, it doesn't know how/when to unwrap the ReadOnlyVector before inserting into the dict
			x2 = @inferred deduplicate!(d, x; transfer_ownership=true)
			@test x2 isa ROVec{Int}
			@test x2 === x
		end

		let x = [[0,0], [1,1], [2,2]]
			x2 = @inferred deduplicate!(d, x; transfer_ownership=true)
			@test x2 == x
			@test x2 isa ROVec{ROVec{Int}}
			@test parent(x2) !== x # A copy was made for x2 because eltype changed to ROVec when children were deduplicated
			@test parent(x2[1]) == x[1]
			@test parent(x2[2]) == x[2]
			@test parent(x2[3]) == x[3]
		end

		let x = Union{Int,Nothing}[0, 1]
			x2 = @inferred ROVec{<:Union{Int,Nothing}} deduplicate!(d, x; transfer_ownership=true)
			@test x2 == x
			@test x2 isa ROVec{Int}
			@test parent(x2) !== x # A copy was made for x2 because eltype was canonicalized
		end

		# Hmm. What behavior do we want here, currently a copy is made, because we are not sure whether the eltype will change or not.
		# Can we handle that better and avoiding the copy if the eltype doesn't change?
		# let x = Union{Int,Nothing}[0, 1, nothing]
		# 	x2 = @inferred deduplicate!(d, x; transfer_ownership=true)
		# 	@test x2 isa ROVec{Union{Int,Nothing}}
		# 	@test parent(x2) === x
		# end
	end


	@testset "Recursive transfer_ownership=$b" for b in (false, true)
		d = Deduplicator()

		# When using Reporter, it will test that it is called with `transfer_ownership` set recursively.
		@testset "$(typeof(x))" for x in [ [Reporter(b)],
		                                   ReadOnlyArray([Reporter(b)]),
		                                   @view([Reporter(b)][1:1]),
		                                   (Reporter(b),),
		                                   (; a=Reporter(b)),
		                                   1=>Reporter(b),
		                                   Reporter(b)=>1,
		                                   Reporter(b)=>Reporter(b),
		                                   Dict(1=>Reporter(b)),
		                                   Dict(Reporter(b)=>1),
		                                   Dict(Reporter(b)=>Reporter(b)),
		                                   Set((Reporter(b),)),
		                                   Returns(Reporter(b)),
		                                   Base.Fix{1}(identity, Reporter(b)),
		                                   Base.Fix{1}(Reporter(b), 1),
		                                   Base.Fix{1}(Reporter(b), Reporter(b)),
		                                   Base.Fix{2}(identity, Reporter(b)),
		                                   Base.Fix{2}(Reporter(b), 1),
		                                   Base.Fix{2}(Reporter(b), Reporter(b)),
		                                   ComposedFunction(identity, Reporter(b)),
		                                   ComposedFunction(Reporter(b), identity),
		                                   ComposedFunction(Reporter(b), Reporter(b)),
		                                   DataFrame("a"=>[Reporter(b)]),
		                                 ]
			global reporter_was_called = false
			x2 = @inferred deduplicate!(d, x; transfer_ownership=b)
			@test x2 == x # This only works for e.g. Base.Fix because == and === are the same for Reporter.
			@test reporter_was_called
		end
	end

	@testset "Hash uniqueness" begin
		# d = Deduplicator()

		hashed = Dict{Hash,Any}()
		items = ([5,2], [5;2;;], [5 2], [5;;;2], [5.0,2.0], Int8[5,2], (5,2), 5=>2,
		         (; a=5, b=2), (; a=2, b=5), Set((5,2)), Dict(:a=>5, :b=>2), Dict(:a=>2, :b=>5),
		         sparse([5,2]), sparse([5;2;;]),
		         DataFrame(:a=>[5,2]), DataFrame(:a=>[5.0,2.0]), DataFrame(:b=>[5,2]),
		         [nothing], [missing],
		         [v"0.1.0"], [v"0.1.0-a"], [v"1.0.0"],
		         [r"abc"], [r"abc"i], ["abc"],
		         [Int], [Int8], ["Int"], ["Int8"],
		         ["A"], [:A], [Int('A')], ['A'], [("A",)], [('A',)],
		         [:], [isequal], [in], [!], [!=],
		         Returns([5,2]), in([5,2]), !in([5,2]),
		         <([5,2]), >([5,2]),
		         BitVector((true,false)), [true false], [true;;;false], (true,false),
		         [], (), (;),
		        )
		@testset "$(item isa DataFrame ? "DataFrame" : item)" for item in items
			# Recreate the Deduplicator for every item to ensure we don't return a previous item if they hash equally! (We just want to canonicalize.)
			d = Deduplicator()
			x = deduplicate!(d, item) # convert to canonical form

			# TODO: Replace this with our own isequal function that handles Returns etc
			if item isa Returns
				@test isequal(item.value, x.value)
			elseif item isa Base.Fix2
				@test isequal(item.f, x.f)
				@test isequal(item.x, x.x)
			elseif item isa ComposedFunction
				@test isequal(item.outer, x.outer)
				@test isequal(item.inner.f, x.inner.f)
				@test isequal(item.inner.x, x.inner.x)
			else
				@test isequal(item, x)
			end

			h = deduplication_hash(d, x)
			retrieved = get(hashed, h, x)
			@test x === retrieved
			hashed[h] = x
		end
	end

	@testset "CompoundResult" begin
		d = Deduplicator()
		let x = CompoundResult(; a=[1,5,2], b=[10,20])
			x2 = @inferred deduplicate!(d, x)
			@test x2 isa CompoundResult
			@test x2.keys === x.keys
			@test x2.values == x.values
			@test x2.values !== x.values

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2

			@test !isempty(d.pointer2obj)
		end
		let x = CompoundResult(; u="hej", v=(2,[10,20]))
			x2 = deduplicate!(d, x)
			@test x2 isa CompoundResult
			@test x2.keys === x.keys
			@test x2.values == x.values
			@test x2.values !== x.values

			@test deduplicate!(d, x) === x2
			@test deduplicate!(d, x2) === x2
		end
	end

	@testset "Empty" begin
		d = Deduplicator() # Keep the same deduplicator for all tests below to ensure that they each empty array gets their own hash

		@testset "$T" for T in (Int, String, Regex)
			x = T[]
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROVec{T}
			@test parent(x2) !== x

			@test @inferred(deduplicate!(d, x)) === x2
			@test @inferred(deduplicate!(d, x2)) === x2
		end
		@testset "$x" for x in (Int[;;], Int[;;;], zeros(Int,3,0), zeros(Int,0,3), zeros(Int,0,3,0))
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROArray{eltype(x), ndims(x)}
			@test parent(x2) !== x

			@test @inferred deduplicate!(d, x) === x2
			@test @inferred deduplicate!(d, x2) === x2
		end
		let x = Union{Int,Nothing}[]
			x2 = deduplicate!(d, x)
			@test x2 == x
			@test x2 isa ROVec{Union{Int,Nothing}}
			@test parent(x2) !== x

			@test deduplicate!(d, x) === x2
			@test deduplicate!(d, x2) === x2
		end

		@testset "Dict{$K,$V}" for (K,V) in ((Int,Int),(Int,String))
			x = Dict{K,V}()
			x2 = @inferred deduplicate!(d, x)
			@test x2 == x
			@test x2 !== x
			@test x2 isa Dict{K,V}

			@test @inferred deduplicate!(d, x) === x2
			@test @inferred deduplicate!(d, x2) === x2
		end
	end
end
