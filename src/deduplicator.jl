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


# We should consider deduplicating elements in Arrays/Dicts/Tuples/NamedTuples
# But that makes the return type of `deduplicate!` much harder to infer.
# So maybe not worth it.
# deduplicator_copy(dedup::Deduplicator, a::Array) = deduplicate!.(Ref(dedup), a)
# deduplicator_copy(dedup::Deduplicator, d::Dict{K}) where K =
# 	Dict{K}((k=>deduplicate!(dedup,v) for (k,v) in d))
# deduplicator_copy(dedup::Deduplicator, t::Tuple) = deduplicate!.(Ref(dedup), t)
# deduplicator_copy(dedup::Deduplicator, nt::NamedTuple) =
# 	NamedTuple((k=>deduplicate!(dedup,v) for (k,v) in nt))



# "Shortcut" for some simple types, to lower risk of type instabilities in deduplicate!
deduplicate_type(::Deduplicator, ::Type{<:Union{<:Integer,<:AbstractFloat,String,Symbol}}) = false
deduplicate_type(::Deduplicator, ::Type{VersionNumber}) = false # Fix for VersionNumber that otherwise runs into Vararg problems below

# Does these result in type instable code in deduplicate? No, nothing bad, we will get a small union.
function deduplicate_type(dedup::Deduplicator, ::Type{T}) where {T<:Union{Tuple,NamedTuple}}
	# TODO: handle VarArgs by checking Base.isvarargtype(T.parameters[end])? (fieldtypes errors for Vararg.)
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
