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


copy_arg(x::Union{<:Array,<:Dict,<:Set}) = x # already copied in copy_nested
copy_arg(x::AbstractString) = string(x) # Standardize strings
copy_arg(x::Symbol) = x # symbols are immutable, pass through
copy_arg(f::VersionedFunction) = f
copy_arg(c::Colon) = c
copy_arg(f::Union{<:Base.Fix1,<:Base.Fix2}) = f # TODO: revise (or revise in copy_nested)
copy_arg(x::DataType) = x
copy_arg(x) = copy(x)

deduplicate_leaves(dedup::Deduplicator) = Base.Fix1(deduplicate_leaves, dedup)
deduplicate_leaves(dedup::Deduplicator, x::Union{<:Array,<:Dict,<:Set}) =
	_is_leaf(x) ? dedup(x) : x
deduplicate_leaves(::Deduplicator, x::Any) = x

