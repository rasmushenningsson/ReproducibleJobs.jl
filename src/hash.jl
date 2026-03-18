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

function StableHashTraits.transformer(::Type{Char}, ::DeduplicatorHashContext)
	StableHashTraits.Transformer(x->(nameof(Char), Int(x)))
end
