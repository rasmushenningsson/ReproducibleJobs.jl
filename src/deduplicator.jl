struct Deduplicator{T}
	hash_context::T
	d::Dict{String,Any} # stable_hash to value. TODO: Make weak instead of keeping everything forever.
end
Deduplicator(hash_context::T) where T = Deduplicator{T}(hash_context, Dict{String,Any}())


# TODO: Figure out the details here.
deduplicator_copy(::Deduplicator, x) = deepcopy(x)


# Can we use mutability somehow to determine whether to deduplicate or pass-through?
# Needs to be recursive however...
deduplicate!(::Deduplicator, x::Union{<:Integer,<:AbstractFloat,String,Symbol}) = x
deduplicate!(::Deduplicator, x::AbstractRange{T}) where {T<:Union{<:Integer, AbstractFloat}} = x # limit to only types in base? Using abstract types could interact weirdly with user-defined types that are not necessarily immutable.

# If the user provides a ReadOnly, we trust the hash of that.
# But we still deduplicate! Just no need to copy the value.
function deduplicate!(dedup::Deduplicator, ro::ReadOnly{T}) where T
	y = get!(dedup.d, ro.h) do
		ro.value
	end
	ReadOnly{T}(y, ro.h)
end

function deduplicate!(dedup::Deduplicator, x::T) where T
	h = bytes2hex(stable_hash(x, dedup.hash_context))
	y = get!(dedup.d, h) do
		deduplicator_copy(dedup, x)
	end
	ReadOnly{T}(y,h)
end
