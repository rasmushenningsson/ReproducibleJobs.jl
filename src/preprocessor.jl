# preprocess_copy(x) = copy(x)


# TODO: We might want to avoid dynamic below to speed it up. But that's for later.

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



# preprocessor(dedup) = Base.Fix1(preprocess, dedup)

# function preprocess(dedup, a::Array)
# 	r = ReadOnlyArray(a)
# 	_is_leaf(r) ? dedup(r) : r
# end
# preprocess(dedup, d::Dict) = _is_leaf(d) ? dedup(d) : d
# preprocess(dedup, s::Set) = _is_leaf(s) ? dedup(s) : s

# preprocess(::Any, x::Any) = preprocess(x)

# preprocess(x::AbstractString) = string(x) # Standardize strings
# preprocess(x::Symbol) = x # symbols are immutable, pass through
# preprocess(f::VersionedFunction) = f
# preprocess(f::Union{<:Base.Fix1,<:Base.Fix2}) = f # TODO: revise (or revise in copy_nested)


# preprocess(x::Any) = preprocess_copy(x)




preprocess(a::Array) = ReadOnlyArray(a)
preprocess(x::Any) = x

preprocess_copy(x::Union{<:ReadOnlyArray,<:Dict,<:Set}) = x # already copied in copy_nested
preprocess_copy(x::AbstractString) = string(x) # Standardize strings
preprocess_copy(x::Symbol) = x # symbols are immutable, pass through
preprocess_copy(f::VersionedFunction) = f
preprocess_copy(f::Union{<:Base.Fix1,<:Base.Fix2}) = f # TODO: revise (or revise in copy_nested)
preprocess_copy(x) = copy(x)

deduplicate_leaves(dedup::Deduplicator) = Base.Fix1(deduplicate_leaves, dedup)
deduplicate_leaves(dedup::Deduplicator, x::Union{<:ReadOnlyArray,<:Dict,<:Set}) =
	_is_leaf(x) ? dedup(x) : x
deduplicate_leaves(::Deduplicator, x::Any) = x

