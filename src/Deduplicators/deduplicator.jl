deduplicate_type(::Type{T}) where T<:Union{<:Number,String,Symbol,Char,DataType,Colon,Nothing,Missing,VersionNumber,Regex} = false

deduplicate_type(::Type{<:AbstractUnitRange{T}}) where T<:Union{Number,Char} = false
deduplicate_type(::Type{<:AbstractRange{T}}) where T<:Union{Number,Char} = false

# Simple temporary(?) solution for allowing some functions to be used as arguments
const SupportedFunctions = Union{typeof(identity), typeof(!), typeof(iszero), typeof(ismissing), typeof(isequal), typeof(startswith), typeof(only), typeof(in), typeof(<), typeof(<=), typeof(>), typeof(>=), typeof(==), typeof(!=)}
deduplicate_type(::Type{T}) where T<:SupportedFunctions = false

deduplicate_type(::Type{<:Exception}) = false




# Helper function, only used by (Abstract)Arrays a.t.m.
function _deduplicate_eltype(::Type{T}) where T
	if T isa Union
		_deduplicate_eltype(T.a) || _deduplicate_eltype(T.b)
	else
		isconcretetype(T) ? deduplicate_type(T) : true # for non-concrete types we are not sure and must return true so that it is handled for each child separately
	end
end
function _deduplicate_eltype(::Type{<:Pair{K,V}}) where {K,V}
	_deduplicate_eltype(K) || _deduplicate_eltype(V)
end
function _deduplicate_eltype(::Type{<:Pair}) # This case catches unbound type parameters
	true
end



deduplication_type_already_copied(::Type{T}) where T = false

deduplication_preprocess(x::Any) = x # NB: deduplicate_type should be specified also for types that unwrap using deduplication_preprocess, otherwise nesting is not handled properly, since we need to look at eltypes before preprocessing has occurred.
deduplication_postprocess(x::Any) = x

deduplication_pointer(::Any) = nothing
canonicalize(x::Any) = x

function deduplicate_children! end
function deduplication_hash end




# TODO: figure out a strategy for cleaning out entries where the weakref is nothing

# Maybe support type param that is only used to ensure return values are typed (because WeakRef doesn't have a type param)
struct Deduplicator{H}
	hash_context::H

	pointer2obj::Dict{Ptr{Nothing},Tuple{WeakRef,Hash}}
	hash2obj::Dict{Hash,WeakRef}

	# @atomic cleanup_needed::Bool # TODO: Do something like this to keep track of we need to remove old dangling references. Probably a counter though so we don't do it too often.
end
Deduplicator(hash_context::H) where H = Deduplicator{H}(hash_context, Dict{Ptr{Nothing},Tuple{WeakRef,Hash}}(), Dict{Hash,WeakRef}())
Deduplicator() = Deduplicator(DeduplicatorHashContext())


function Base.empty!(d::Deduplicator)
	empty!(d.pointer2obj)
	empty!(d.hash2obj)
	d
end


function compute_hash(d::Deduplicator{H}, x::T) where {H,T}
	Hash(stable_hash(x, d.hash_context))
end




function value_from_pointer(d::Deduplicator, p::Union{Nothing, Ptr{Nothing}})
	p === nothing && return nothing
	tup = get(d.pointer2obj, p, nothing)
	tup === nothing && return nothing
	tup[1].value # value or nothing
end

function value_from_hash(d::Deduplicator, h::Hash)
	w = get(d.hash2obj, h, nothing)
	w === nothing && return nothing
	w.value # value or nothing

	# If we get here, with a value of `nothing`, there was an old entry which is no longer valid. (This can happen when a new pointer gets the same exact address as a previously freed pointer.)
	# TODO: Can we do a cleanup of the old entry?
	#       Yes, at least in d.hash2obj.
end


function lookup_hash(d::Deduplicator, x::T) where T
	p = deduplication_pointer(x)
	p === nothing && return nothing
	tup = get(d.pointer2obj, p, nothing)

	@assert tup !== nothing # Since `x` is alive, the pointer must refer to `x` and the weakref must refer to `x`. So it cannot be nothing.

	# value = tup[1].value
	# value === nothing && return nothing # I don't think this can happen, because all children are deduplicated before we lookup their hashes, so we know that `x` is in the deduplicator and thus the weakref must refer to `x` since it is still alive.
	# return tup[2]

	@assert tup[1].value !== nothing # Since `x` is alive, the pointer must refer to `x` and the weakref must refer to `x`. So it cannot be nothing.
	return tup[2]
end



function hash_or_value(d, x::T)::Union{T,Hash} where T
	if deduplicate_type(T)
		h = lookup_hash(d, x)
		h !== nothing ? h : deduplication_hash(d, x)
	else
		return x
	end
end



# function _deduplication_cleanup_item!(d::Deduplicator, p::Ptr{Nothing})
# 	tup = get(d.pointer2obj, p, nothing)
# 	if tup !== nothing
# 		w,h = d.pointer2obj[p]
# 		if w.value === nothing
# 			delete!(d.pointer2obj, p)
# 		end
# 		w2 = get(d.hash2obj, h, nothing)
# 		if w2 !== nothing && w2.value === nothing
# 			delete!(d.hash2obj, h)
# 		end 
# 	end
# end


# function _deduplication_cleanup!(d::Deduplicator)
# end


function insert_item!(d::Deduplicator, p, x, h)
	@assert ismutable(x)
	w = WeakRef(x)
	# finalizer(..., x) # TODO: Add a finalizer to be able to track when cleanup is needed
	d.pointer2obj[p] = (w,h)
	d.hash2obj[h] = w
end


# TESTING
deconstruct_type(::Type{T}) where T = false

function deconstruct end
function reconstruct end


# Default implementation (only possible for deconstructed types)
function deduplication_hash(d, x::T) where T
	@assert deconstruct_type(T)
	xd = deconstruct(x)::Tuple
	compute_hash(d, (type_to_tag(T), hash_or_value.(Ref(d), xd)...))
end

deconstruct_type(::Type{<:Tuple}) = true
type_to_tag(::Type{<:Tuple}) = TypeTag(:Tuple)
tag_to_type(::Val{:Tuple}) = Tuple
deconstruct(t::Tuple) = t
reconstruct(::Type{<:Tuple}, t::T) where T<:Tuple = t

deconstruct_type(::Type{<:Pair}) = true
type_to_tag(::Type{<:Pair}) = TypeTag(:Pair)
tag_to_type(::Val{:Pair}) = Pair
deconstruct((k,v)::Pair) = (k,v)
reconstruct(::Type{<:Pair}, (k,v)::Tuple{K,V}) where {K,V} = k=>v

# This relies on internals (Base._Set) to create a no-copy Set from a Dict{K,Nothing}.
deconstruct_type(::Type{<:Set}) = true
type_to_tag(::Type{<:Set}) = TypeTag(:Set)
tag_to_type(::Val{:Set}) = Set
deconstruct(s::Set{T}) where T = (s.dict, )
reconstruct(::Type{<:Set}, (d,)::Tuple{Dict{K,Nothing}}) where K = Base._Set(d) # This doesn't copy the elements - using Set() would

deconstruct_type(::Type{<:Returns}) = true
type_to_tag(::Type{<:Returns}) = TypeTag(:Returns)
tag_to_type(::Val{:Returns}) = Returns
deconstruct(r::Returns{T}) where T = (r.value, )
reconstruct(::Type{<:Returns}, (x,)::Tuple{T}) where T = Returns(x)

deconstruct_type(::Type{<:Base.Fix}) = true
type_to_tag(::Type{<:Base.Fix}) = TypeTag(:Fix)
tag_to_type(::Val{:Fix}) = Base.Fix
deconstruct(fix::Base.Fix{N,F,T}) where {N,F,T} = (N, fix.f, fix.x)
function reconstruct(::Type{<:Base.Fix{N}}, (n,f,x)::Tuple{Int,F,T}) where {N,F,T}
	@assert N == n
	Base.Fix{N}(f, x)
end
function reconstruct(::Type{<:Base.Fix}, (n,f,x)::Tuple{Int,F,T}) where {F,T} # type unstable version when N isn't known at the type level
	Base.Fix{n}(f, x)
end

deconstruct_type(::Type{<:ComposedFunction}) = true
type_to_tag(::Type{<:ComposedFunction}) = TypeTag(:ComposedFunction)
tag_to_type(::Val{:ComposedFunction}) = ComposedFunction
deconstruct(c::ComposedFunction{F1,F2}) where {F1,F2} = (c.outer, c.inner)
reconstruct(::Type{<:ComposedFunction}, (outer,inner)::Tuple{F1,F2}) where {F1,F2} = outer ∘ inner

deconstruct_type(::Type{<:SparseMatrixCSC}) = true
type_to_tag(::Type{<:SparseMatrixCSC}) = TypeTag(:SparseMatrixCSC)
tag_to_type(::Val{:SparseMatrixCSC}) = SparseMatrixCSC
deconstruct(X::SparseMatrixCSC{Tv,Ti}) where {Tv,Ti} = (X.m, X.n, X.colptr, X.rowval, X.nzval) # Use NamedTuple instead?
reconstruct(::Type{<:SparseMatrixCSC}, (m,n,colptr,rowval,nzval)::Tuple{Int,Int,ROVec{Ti},ROVec{Ti},ROVec{Tv}}) where {Tv,Ti} =
	SparseMatrixCSC{Tv,Ti}(m, n, parent(colptr), parent(rowval), parent(nzval))

deconstruct_type(::Type{<:SparseVector}) = true
type_to_tag(::Type{<:SparseVector}) = TypeTag(:SparseVector)
tag_to_type(::Val{:SparseVector}) = SparseVector
deconstruct(X::SparseVector{Tv,Ti}) where {Tv,Ti} = (X.n, X.nzind, X.nzval) # Use NamedTuple instead?
reconstruct(::Type{<:SparseVector}, (n,nzind,nzval)::Tuple{Int,ROVec{Ti},ROVec{Tv}}) where {Tv,Ti} =
	SparseVector{Tv,Ti}(n, parent(nzind), parent(nzval))



deduplicate_type(::Type{<:CompoundResult}) = true
deconstruct_type(::Type{<:CompoundResult}) = true
type_to_tag(::Type{<:CompoundResult}) = TypeTag(:CompoundResult)
tag_to_type(::Val{:CompoundResult}) = CompoundResult # never used?
deconstruct(cr::CompoundResult) = (cr.keys, cr.values)
reconstruct(::Type{<:CompoundResult}, (keys,values)::Tuple{ROVec{String},ROVec{T}}) where T = CompoundResult(keys, parent(values))




function _deduplicate!(d::Union{Deduplicator,Nothing}, x::T, transfer_ownership::Bool, already_copied::Bool) where T # can we find a better name than transfer_ownership?
	# _deduplication_cleanup!(d) # TODO: Add

	already_copied = already_copied || transfer_ownership

	# # TODO: Can we find a nicer way to do this?
	# if x isa ReadOnlyArray
	# 	x = parent(x)
	# 	already_copied = true
	# else
	# 	already_copied = transfer_ownership
	# end


	# TESTING
	if deconstruct_type(T)
		xd = deconstruct(x)
		xd = deduplicate_children!(d, xd; transfer_ownership)
		return reconstruct(T, xd)
	end



	# 1. Is it already deduplicated using the same pointer? (Early out)
	p = deduplication_pointer(x)
	initial_p = p
	if d !== nothing
		value = value_from_pointer(d, p)
		value !== nothing && return value
	end

	# 2. Ensure children are deduplicated
	x = deduplicate_children!(d, x; transfer_ownership)

	# 3. Canonicalize
	x = canonicalize(x) # TODO: Maybe skip calling this if deduplicate_children! returned a new object?

	# 4. If it is not pointer-backed, return it as is (it is a simple wrapper around deduplicated objects (e.g. a Tuple))
	p = deduplication_pointer(x)
	p === nothing && return x

	# 5. Try to deduplicate using hash
	if d !== nothing
		h = deduplication_hash(d, x)
		value = value_from_hash(d, h)
		value !== nothing && return value
	end

	# 6. Copy if needed
	# if !read_only && p === initial_p # TODO: Have some kind of flag to indicate when we never need to copy because we want to transfer ownership to the deduplicator
	# if p === initial_p
	if !already_copied && p === initial_p
		x = deduplication_copy(x) # We didn't copy before so we need to do it now.
		p = deduplication_pointer(x)
	end

	# 7. insert new
	if d !== nothing
		insert_item!(d, p, x, h)
	end

	return x
end


function deduplicate_impl!(d::Union{Deduplicator,Nothing}, x::T, transfer_ownership, already_copied) where T
	if deduplicate_type(T)
		# This is needed to infer the return type for values that have already been deduplicated! (Because we store everything in one Dict and value type is thus lost.)
		T2 = Core.Compiler.return_type(_deduplicate!, Tuple{Nothing, T, Bool, Bool})
		x_dedup = _deduplicate!(d, x, transfer_ownership, already_copied)
		x_dedup::T2
	else
		x # for simple types like Int
	end
end


# public
# TODO: can we find a better name than transfer_ownership?
function deduplicate!(d::Union{Deduplicator,Nothing}, x::T; transfer_ownership=false) where T
	already_copied = deduplication_type_already_copied(T)
	x = deduplication_preprocess(x)
	x_dedup = deduplicate_impl!(d, x, transfer_ownership, already_copied)
	deduplication_postprocess(x_dedup)
end



# --- Supported types ---

# AbstractArrays (deduplicated as ReadOnlyArrays wrapping Arrays)
deduplicate_type(::Type{<:AbstractArray}) = true

deduplication_type_already_copied(::Type{<:Union{ROArray,ROBitArray}}) = true

deduplication_preprocess(x::ROArray{T,N}) where {T,N} = parent(x)
deduplication_preprocess(x::ROBitArray{N}) where N = parent(x)

deduplication_postprocess(x::Array{T,N}) where {T,N} = ReadOnlyArray(x)
deduplication_postprocess(x::BitArray{N}) where N = ReadOnlyArray(x)

deduplication_pointer(a::Array) = pointer_from_objref(a)
deduplication_pointer(a::BitArray) = pointer_from_objref(a)

function deduplicate_children!(d, a::AbstractArray{T}; kwargs...) where T
	if _deduplicate_eltype(T)
		deduplicate!.(Ref(d), a; kwargs...) # This can mysteriously change eltype from e.g. Pair{Int,Any} to Pair{Int} - why is that? How do I avoid it?
	else
		a # nothing to do
	end
end



# function canonicalize(a::Union{Array{T},ROArray{T}}) where T
function canonicalize(a::Array{T}) where T
	if !isconcretetype(T) || T === Bool # NB: We need Bool here because `identity.(a)` will change it to BitArray.
		identity.(a)
	else
		a # TODO: Are there more cases where we can ensure the eltype will not be changed?
	end
end
canonicalize(a::AbstractArray{T}) where T = identity.(a)
canonicalize(a::BitArray) = a


_fix_pair_eltype(v::Array{<:Any}) = v
function _fix_pair_eltype(v::Array{<:Pair})
	K = typejoin((typeof(p.first) for p in v)...)
	V = typejoin((typeof(p.second) for p in v)...)
	convert(Array{Pair{K,V}}, v)
end
function _fix_pair_eltype(v::Array{<:Pair{K}}) where K
	V = typejoin((typeof(p.second) for p in v)...)
	convert(Array{Pair{K,V}}, v)
end
_fix_pair_eltype(v::Array{<:Pair{K,V}}) where {K,V} = v


function deduplication_hash(d, a::Array{T,N}) where {T,N}
	if isempty(a)
		compute_hash(d, (T, size(a))) # The size is needed to distinguish between Vector/Matrix but also between e.g. a 3×0 and a 0×0 matrix.
	elseif _deduplicate_eltype(T)
		# # Replace deduplicatable children by their hash
		# compute_hash(d, (hash_or_value.(Ref(d), a))

		# Replace deduplicatable children by their hash
		hv = hash_or_value.(Ref(d), a)
		hv = _fix_pair_eltype(hv) # Workaround for handling UnionAll Pairs (e.g. Pair{Int} or Pair{K,Int} where K)
		compute_hash(d, hv)
	else
		# Fast path
		compute_hash(d, a)
	end
end
function deduplication_hash(d, a::BitVector)
	# NB: This relies on trailing bits in `chunks` being set to 0.
	# NB: The a.dims parameter is unused for BitVectors, so don't include it in the Hash.
	compute_hash(d, (TypeTag(:BitVector), a.chunks, a.len))
end
function deduplication_hash(d, a::BitArray)
	# NB: This relies on trailing bits in `chunks` being set to 0.
	compute_hash(d, (TypeTag(:BitArray), a.chunks, a.len, a.dims))
end
deduplication_hash(d, ro::ROArray{T,N}) where {T,N} = deduplication_hash(d, ro.parent)
deduplication_hash(d, ro::ROBitArray{N}) where {N} = deduplication_hash(d, ro.parent)

deduplication_copy(a::Array) = copy(a)
deduplication_copy(a::BitArray) = copy(a)
# deduplication_copy(ro::ROArray{T,N}) where {T,N} = parent(ro) # Must return an object of a mutable type, and it's fine to return the parent, because everything in the Deduplicator is readonly


# Tuples
function deduplicate_type(::Type{T}) where T<:Tuple
	any(deduplicate_type, fieldtypes(T))
end
function deduplicate_children!(d, t::T; kwargs...) where T<:Tuple
	# deduplicate!.(Ref(d), t; kwargs...) # deduplicate_type already handles the case when deduplicate_children! doesn't need to be called.
	# map is better for inference than broadcast?!
	map(x->deduplicate!(d, x; kwargs...), t) # deduplicate_type already handles the case when deduplicate_children! doesn't need to be called.
end

# NamedTuples
function deduplicate_type(::Type{T}) where T<:NamedTuple
	any(deduplicate_type, fieldtypes(T))
end
function deduplicate_children!(d, nt::T; kwargs...) where T<:NamedTuple
	map(x->deduplicate!(d,x; kwargs...), nt)
end
function deduplication_hash(d, nt::T) where T<:NamedTuple
	compute_hash(d, map(x->hash_or_value(d,x), nt))
end

# Pairs
function deduplicate_type(::Type{Pair{K,V}}) where {K,V}
	# Since we might get Pairs where K or V equals e.g. Any, when putting heterogeneous Pairs in Vectors.
	!isconcretetype(K) || !isconcretetype(V) || deduplicate_type(K) || deduplicate_type(V)
end
deduplicate_type(::Type{<:Pair}) = true # For UnionAll Pairs we must deduplicate to be sure




# Dicts
deduplicate_type(::Type{<:Dict}) = true

deduplication_pointer(dict::Dict) = pointer_from_objref(dict)



function deduplicate_children!(d, dict::Dict{K,V}; kwargs...) where {K,V}
	# dedup_keys = _deduplicate_eltype(K)
	# dedup_values = _deduplicate_eltype(V)
	# if dedup_keys && dedup_values
	# 	Dict(deduplicate!(d, k; kwargs...)=>deduplicate!(d, v; kwargs...) for (k,v) in dict)
	# elseif dedup_values
	# 	Dict(k=>deduplicate!(d, v; kwargs...) for (k,v) in dict)
	# elseif dedup_keys
	# 	Dict(deduplicate!(d, k; kwargs...)=>v for (k,v) in dict)
	# else
	# 	dict # nothing to do
	# end

	dedup_keys = _deduplicate_eltype(K)
	dedup_values = _deduplicate_eltype(V)

	if dedup_keys && dedup_values
		ks = deduplicate!.(Ref(d), keys(dict); kwargs...)
		vs = deduplicate!.(Ref(d), values(dict); kwargs...)
		Dict{eltype(ks), eltype(vs)}(k=>v for (k,v) in zip(ks,vs))
	elseif dedup_values
		vs = deduplicate!.(Ref(d), values(dict); kwargs...)
		Dict{K, eltype(vs)}(k=>v for (k,v) in zip(keys(dict),vs))
	elseif dedup_keys
		ks = deduplicate!.(Ref(d), keys(dict); kwargs...)
		Dict{eltype(ks), V}(k=>v for (k,v) in zip(ks,values(dict)))
	else
		dict # nothing to do
	end

	if dedup_keys && dedup_values
		Dict(deduplicate!(d, k; kwargs...)=>deduplicate!(d, v; kwargs...) for (k,v) in dict)
	elseif dedup_values
		Dict(k=>deduplicate!(d, v; kwargs...) for (k,v) in dict)
	elseif dedup_keys
		Dict(deduplicate!(d, k; kwargs...)=>v for (k,v) in dict)
	else
		dict # nothing to do
	end

end

function canonicalize(dict::Dict{K,V}) where {K,V}
	# if isconcretetype(K) && isconcretetype(V)
	# 	dict # TODO: Are there more cases where we can ensure the eltype will not be changed?
	# else
	# 	Dict(k=>v for (k,v) in dict) # narrow eltype
	# end

	concrete_keys = isconcretetype(K)
	concrete_values = isconcretetype(V)

	if concrete_keys && concrete_values
		dict # TODO: Are there more cases where we can ensure the eltype will not be changed?
	elseif concrete_keys
		vs = identity.(values(dict)) # narrow eltype
		Dict{K, eltype(vs)}(k=>v for (k,v) in zip(keys(dict),vs))
	elseif concrete_values
		ks = identity.(keys(dict)) # narrow eltype
		Dict{eltype(ks), V}(k=>v for (k,v) in zip(ks,values(dict)))
	else
		ks = identity.(keys(dict)) # narrow eltype
		vs = identity.(values(dict)) # narrow eltype
		Dict{eltype(ks), eltype(vs)}(k=>v for (k,v) in zip(ks,vs))
	end
end


function deduplication_hash(d, dict::Dict{K,V}) where {K,V}
	dedup_keys = _deduplicate_eltype(K)
	dedup_values = _deduplicate_eltype(V)

	# Replace deduplicatable children by their hash, sort and compute stable_hash

	if !dedup_keys && !dedup_values
		# Fast path
		return compute_hash(d, dict)
	end

	if dedup_keys
		ks = hash_or_value.(Ref(d), keys(dict))
		ks = _fix_pair_eltype(ks) # Workaround for handling UnionAll Pairs (e.g. Pair{Int} or Pair{K,Int} where K)
	else
		ks = collect(keys(dict))
	end
	if dedup_values
		vs = hash_or_value.(Ref(d), values(dict))
		vs = _fix_pair_eltype(vs) # Workaround for handling UnionAll Pairs (e.g. Pair{Int} or Pair{K,Int} where K)
	else
		vs = collect(values(dict))
	end

	perm = sortperm(ks; lt=mixed_isless)
	ks = ks[perm]
	vs = vs[perm]
	return compute_hash(d, (TypeTag(:Dict), ks, vs))

	# # TODO: Not good enough, StableHashTraits cannot handle the eltypes of the arrays with mixed types - split keys and values into separate arrays (but sort by keys still)
	# if dedup_keys && dedup_values
	# 	pairs = [hash_or_value(d,k)=>hash_or_value(d,v) for (k,v) in dict]
	# 	sort!(pairs; by=first, lt=mixed_isless)
	# 	return compute_hash(d, (TypeTag(:Dict), pairs))
	# elseif dedup_values
	# 	pairs = [k=>hash_or_value(d,v) for (k,v) in dict]
	# 	sort!(pairs; by=first)
	# 	return compute_hash(d, (TypeTag(:Dict), pairs))
	# elseif dedup_keys
	# 	pairs = [hash_or_value(d,k)=>v for (k,v) in dict]
	# 	sort!(pairs; by=first, lt=mixed_isless)
	# 	return compute_hash(d, (TypeTag(:Dict), pairs))
	# else
	# 	# Fast path
	# 	return compute_hash(d, dict)
	# end
end

deduplication_copy(dict::Dict) = copy(dict)



deduplicate_type(::Type{<:Set}) = true


# Returns
function deduplicate_type(::Type{Returns{T}}) where {T}
	deduplicate_type(T)
end
# Base.Fix
function deduplicate_type(::Type{Base.Fix{N,F,T}}) where {N,F,T}
	deduplicate_type(F) || deduplicate_type(T)
end
# ComposedFunction
function deduplicate_type(::Type{ComposedFunction{F1,F2}}) where {F1,F2}
	deduplicate_type(F1) || deduplicate_type(F2)
end


deduplicate_type(::Type{<:SparseMatrixCSC}) = true
deduplicate_type(::Type{<:SparseVector}) = true



deduplicate_type(::Type{<:AbstractDataFrame}) = true
deduplication_pointer(df::DataFrame) = pointer_from_objref(df)

function deduplicate_children!(d, df::AbstractDataFrame; kwargs...)
	cols = (name=>deduplicate!(d,col; kwargs...) for (name,col) in pairs(eachcol(df)))
	DataFrame(cols...; copycols=false)
end

function deduplication_hash(d, df::DataFrame)
	# Should we do this in a smarter way?
	n = names(df)
	h = [hash_or_value(d,col) for col in eachcol(df)]
	compute_hash(d, (TypeTag(:DataFrame), n, h))
end

deduplication_copy(df::DataFrame) = copy(df; copycols=false)
