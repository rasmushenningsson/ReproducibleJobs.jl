struct Deduplicator{T}
	hash_context::T
	d::Dict{String,Any} # stable_hash to value. TODO: Make weak instead of keeping everything forever.
end
Deduplicator(hash_context::T) where T = Deduplicator{T}(hash_context, Dict{String,Any}())




let deduplicator_singleton = Deduplicator(HashVersion{4}())
	global default_deduplicator() = deduplicator_singleton
end





# TODO: Figure out the details here.
deduplicator_copy(::Deduplicator, x) = deepcopy(x)


# "Shortcut" for some simple types, to lower risk of type instabilities in deduplicate!
deduplicate_type(::Deduplicator, ::Type{<:Union{<:Integer,<:AbstractFloat,String,Symbol}}) = false

# Does these result in type instable code in deduplicate? No, nothing bad, we will get a small union.
function deduplicate_type(dedup::Deduplicator, ::Type{T}) where {T<:Union{Tuple,NamedTuple}}
	for S in fieldtypes(T)
		deduplicate_type(dedup, S) && return true
	end
	return false
end
function deduplicate_type(dedup::Deduplicator, ::Type{T}) where {T}
	if T isa Union
		return deduplicate_type(dedup, T.a) || deduplicate_type(dedup, T.b)
	end
	ismutabletype(T) && return true
	for S in fieldtypes(T)
		deduplicate_type(dedup, S) && return true
	end
	return false
end


# If the user provides a ReadOnly, we trust the hash of that.
# But we still deduplicate! Just no need to copy the value.
function deduplicate!(dedup::Deduplicator, ro::ReadOnly{T}) where T
	y = get!(dedup.d, ro.h) do
		ro.value
	end
	ReadOnly{T}(y, ro.h)
end

function deduplicate!(dedup::Deduplicator, x::T) where T
	deduplicate_type(dedup, T) || return x # Rely on const-prop for type stability

	h = bytes2hex(stable_hash(x, dedup.hash_context))
	y = get!(dedup.d, h) do
		deduplicator_copy(dedup, x)
	end
	ReadOnly{T}(y,h)
end
