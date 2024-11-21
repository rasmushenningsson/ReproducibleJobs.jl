struct ReadOnly{T}
	value::T
	h::String # stable_hash
end

get_hash(ro::ReadOnly) = ro.h

_is_leaf_type(::Type{<:ReadOnly}) = false
copy_arg(ro::ReadOnly) = ro # Already managed, no need to copy


function Base.:(==)(a::ReadOnly{T}, b::ReadOnly{T}) where T
	a.h != b.h && return false # early out
	a === b && return true # early out
	return a.value == b.value
end

Base.hash(ro::ReadOnly, h::UInt) = hash(ro.h, h)

# Needed to supported ReadOnly values with other, nested ReadOnly values inside (without recomputing hash values)
StableHashTraits.transformer(::Type{<:ReadOnly}) = StableHashTraits.Transformer(pick_fields(:h))

function Base.show(io::IO, ::MIME"text/plain", ro::ReadOnly{T}) where T
	print(io, ro.value)
	printstyled(io, ' ', ro.h[1:min(6,end)]; color=:red)
end
Base.show(io::IO, ro::ReadOnly) = show(io,MIME"text/plain"(), ro)
