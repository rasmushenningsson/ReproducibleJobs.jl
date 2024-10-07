struct ReadOnly{T}
	value::T
	h::String # stable_hash
end

function Base.:(==)(a::ReadOnly{T}, b::ReadOnly{T}) where T
	a.h != b.h && return false # early out
	a === b && return true # early out
	return a.value == b.value
end

Base.hash(ro::ReadOnly, h::UInt) = hash(ro.h, h)

# Needed to supported ReadOnly values with other, nested ReadOnly values inside (without recomputing hash values)
StableHashTraits.transformer(::Type{<:ReadOnly}) = Transformer(pick_fields(:h))

Base.show(io::IO, ::MIME"text/plain", ro::ReadOnly{T}) where T =
	print(io, "ReadOnly{$T}(", ro.h[1:min(6,end)], ',', ro.value, ')')
Base.show(io::IO, ro::ReadOnly) = show(io,MIME"text/plain"(), ro)
