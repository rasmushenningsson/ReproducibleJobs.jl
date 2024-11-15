preprocess_copy(x) = copy(x)


# # TODO: We might want to avoid dynamic dispatch for pre-processing to speed it up. But that's for later.

# # This are handled by copy_nested and are thus already new copies
# preprocess_standard(a::Array) = a
# preprocess_standard(d::Dict) = d
# preprocess_standard(t::Tuple) = t
# preprocess_standard(p::Pair) = p


# preprocess_standard(x::AbstractString) = string(x) # Standardize strings
# preprocess_standard(x::Symbol) = x # symbols are immutable, pass through
# preprocess_standard(f::VersionedFunction) = f
# preprocess_standard(f::Union{<:Base.Fix1,<:Base.Fix2}) = f

# preprocess_standard(x) = preprocess_copy(x)




# First attempt at new preprocessing. Seems cumbersome.
# struct Preprocessor{T}
# 	deduplicator::T
# 	deduplicated::Bool
# end
# Preprocessor(dedup::T) where T = Preprocessor(dedup, false)
# Preprocessor(p::Preprocessor, deduplicated) = Preprocessor(p.deduplicator, deduplicated)


# function (p::Preprocessor{T})(a::ReadOnlyArray)
# 	p.deduplicated && return p,a # Do not do nested deduplication, only deduplicate "leaves"
# 	Preprocessor(p,true), p.deduplicator(a)
# end


# # No. This is incorrect. Doesn't handle Any like I want.
# function _is_leaf_type(::Type{T}) where T
# 	T isa Union && return _is_leaf_type(T.a) || _is_leaf_type(T.b)
# 	# T <: Barrier && return false
# 	T <: Spec && return false
# 	T <: ReadOnly && return false
# 	T <: AbstractArray && return false
# 	T <: AbstractDict && return false
# 	T <: AbstractSet && return false
# 	if (T <: Pair) || (T <: Tuple) || (T <: NamedTuple)
# 		return all(_is_leaf_type, fieldtypes(T))
# 	end
# 	return true
# end


# _is_leaf(a::ReadOnlyArray{T}) where T = _is_leaf(parent(a))

# function _is_leaf(a::Array{T}) where T
# 	if _is_leaf_type(T)
# 		return true
# 	else
# 		# We come here if we don't know, e.g. if T == Any
# 		for x in a
# 			_is_leaf_type(typeof(x)) || return false # early out
# 		end
# 		return true
# 	end

# 	# If T could be Spec/ReadOnly/Array/Dict/Set, go through elements
# 	# otherwise we know it must be a leaf
# end

# _is_leaf_type is only called for concrete types
_is_leaf_type(::Type{<:AbstractArray}) = false
_is_leaf_type(::Type{<:AbstractSet}) = false
_is_leaf_type(::Type{<:AbstractDict}) = false
_is_leaf_type(::Type{T}) where {T<:Union{<:Pair,<:Tuple,<:NamedTuple}} = all(_is_leaf_type, fieldtypes(T))
_is_leaf_type(::Type{T}) where T = true


# eltype can be Unions and non-concrete types
function is_leaf_eltype(::Type{T}) where T
	T isa Union && return is_leaf_eltype(T.a) && is_leaf_eltype(T.b)
	isconcretetype(T) && return _is_leaf_type(T)
	return false
end

function _is_leaf(a::Array{T}) where T
	is_leaf_eltype(T) && return true # early out
	# We come here if cannot know it's a leaf, e.g. if T == Any
	for x in a
		_is_leaf_type(typeof(x)) || return false
	end
	return true
end
_is_leaf(a::ReadOnlyArray{T}) where T = _is_leaf(parent(a))


function _is_leaf(d::Dict{K,V}) where {K,V}
	is_leaf_eltype(K) && is_leaf_eltype(V) && return true # early out
	# We come here if cannot know it's a leaf, e.g. if K or V == Any
	for (k,v) in pairs(d)
		_is_leaf_type(typeof(k)) || return false
		_is_leaf_type(typeof(v)) || return false
	end
	return true
end


# TODO: Merge with Array implementation above?
function _is_leaf(s::Set{T}) where T
	is_leaf_eltype(T) && return true # early out
	# We come here if cannot know it's a leaf, e.g. if T == Any
	for x in s
		_is_leaf_type(typeof(x)) || return false
	end
	return true
end



# preprocess(dedup) = x->preprocess(dedup, x)
preprocessor(dedup::Deduplicator) = Base.Fix1(preprocess, dedup)

function preprocess(dedup::Deduplicator, a::Array)
	r = ReadOnlyArray(a)
	_is_leaf(r) ? dedup(r) : r
end
preprocess(dedup::Deduplicator, d::Dict) = _is_leaf(d) ? dedup(d) : d
preprocess(dedup::Deduplicator, s::Set) = _is_leaf(s) ? dedup(s) : s

preprocess(::Deduplicator, x::Any) = preprocess(x)

preprocess(x::AbstractString) = string(x) # Standardize strings
preprocess(x::Symbol) = x # symbols are immutable, pass through
preprocess(f::VersionedFunction) = f
preprocess(f::Union{<:Base.Fix1,<:Base.Fix2}) = f # TODO: revise (or revise in copy_nested)


preprocess(x::Any) = preprocess_copy(x)
