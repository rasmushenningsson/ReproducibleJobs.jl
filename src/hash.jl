struct Hash
	v::NTuple{4,UInt64}
end
function Hash(a::Array{UInt8})
	@assert length(a) == 32
	Hash(NTuple{4,UInt64}(reinterpret(UInt64,a)))
end
Hash(s::String) = Hash(hex2bytes(s))

Base.isless(h1::Hash, h2::Hash) = isless(h1.v, h2.v)
mixed_isless(h1::Hash, h2::Hash) = isless(h1,h2)
mixed_isless(h::Hash, x) = true
mixed_isless(x, h::Hash) = false
mixed_isless(x1, x2) = isless(x1,x2)


# We could consider doing this without materializing an intermediate array, but the code gets more messy
hash_string(h::Hash) = bytes2hex(reinterpret(UInt8, [h.v...]))

Base.show(io::IO, h::Hash) = print(io, "Hash(\"", hash_string(h), "\")")


"""
	struct TypeTag
		name::Symbol
	end

In `deduplication_hash`, we often transform the value we want to hash to e.g. a `Tuple`.
In that case, we want to include a `TypeTag(:original_type_name)` in the tuple to distinguish it from an ordinary tuple with the same values, to avoid hash collisions.
"""
struct TypeTag
	name::Symbol
end



struct DeduplicatorHashContext{T}
	parent::T
end
DeduplicatorHashContext() = DeduplicatorHashContext(HashVersion{4}())

StableHashTraits.parent_context(x::DeduplicatorHashContext) = x.parent

# StableHashTraits identifies a type by its StructTypes trait unless an explicit `transform_type`
# method says otherwise, but hashes values as their raw contents. Types sharing a trait therefore
# collide whenever their contents agree. Appending the concrete type name fixes that. (Upstream does
# the same for Symbol, which would otherwise collide with String.)
#
# Handle Union{} edge case.
function StableHashTraits.transform_type(::Type{Union{}}, c::DeduplicatorHashContext)
	StableHashTraits.transform_type(Union{}, StableHashTraits.parent_context(c))
end

# NumberType: Int64[0,0] vs Float64[0.0,0.0], or UInt64 vs Int64 for *every* value.
function StableHashTraits.transform_type(::Type{T}, c::DeduplicatorHashContext) where {T<:Number}
	(StableHashTraits.transform_type(T, StableHashTraits.parent_context(c)), StableHashTraits.nameof_string(T))
end

# StringType: 'a' vs "a", and v"1.2.3" vs "1.2.3".
function StableHashTraits.transform_type(::Type{T}, c::DeduplicatorHashContext) where {T<:Union{Char,String,VersionNumber}}
	(StableHashTraits.transform_type(T, StableHashTraits.parent_context(c)), StableHashTraits.nameof_string(T))
end
