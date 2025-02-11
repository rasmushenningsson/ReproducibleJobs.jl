struct Deduplicator{T}
	hash_context::T
	d::Dict{String,Any} # stable_hash to value. TODO: Make weak instead of keeping everything forever.
end
Deduplicator(hash_context::T) where T = Deduplicator{T}(hash_context, Dict{String,Any}())




let deduplicator_singleton = Deduplicator(HashVersion{4}())
	global default_deduplicator() = deduplicator_singleton
end


# "Shortcut" for some simple types, to lower risk of type instabilities in deduplicate!
deduplicate_type(::Deduplicator, ::Type{<:Union{<:Pair,<:Tuple,<:NamedTuple}}) = false
deduplicate_type(::Deduplicator, ::Type{<:Union{<:Integer,<:AbstractFloat,String,Char,Symbol}}) = false
deduplicate_type(::Deduplicator, ::Type{VersionNumber}) = false # Fix for VersionNumber that otherwise runs into Vararg problems below


# Does these result in type instable code during deduplication? No, nothing bad, we will get a small union.
function deduplicate_type(dedup::Deduplicator, ::Type{T}) where {T}
	if T isa Union
		return deduplicate_type(dedup, T.a) || deduplicate_type(dedup, T.b)
	end
	ismutabletype(T) && return true
	T === Any && return true
	for S in fieldtypes(T)
		deduplicate_type(dedup, S) && return true
	end
	return false
end





# If the user provides a ReadOnly, we trust the hash of that.
# But we still need to insert in the Dict. (TODO: make this recursive!)
# function (dedup::Deduplicator)(ro::ReadOnly{T}) where T
# 	y = get!(dedup.d, ro.h) do
# 		ro.value
# 	end
# 	ReadOnly{T}(y, ro.h)
# end


function (dedup::Deduplicator)(ro::ReadOnly{T}) where T
	y = get(dedup.d, ro.h, nothing)
	y !== nothing && return ReadOnly{T}(y, ro.h)

	ro2 = dedup(ro.value)
	ro.h == ro2.h || @warn "Rehashing ReadOnly resulted in a new hash! (new: $(ro2.h), old: $(ro.h))"
	ro2
end


function (dedup::Deduplicator{D})(x::T) where {D,T}
	deduplicate_type(dedup, T) || return x # Rely on const-prop for type stability

	h = bytes2hex(stable_hash(x, dedup.hash_context))
	y = get!(dedup.d, h, x)
	ReadOnly{T}(y,h)
end
