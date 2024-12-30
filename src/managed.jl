struct Managed{T}
	x::T
end

# TODO: Do we need to implement hash/== by forwarding somehow?

manage(x) = Managed(x)
manage(x::Managed) = x

# TODO: handle basic types like Int etc


# Anyone using this must treat the object (and any nested objects within) as read-only
unsafe_unmanage(m::Managed) = m.x


# How to do nested unmanage properly?
# unmanage(m::Managed{<:Array}) = ReadOnlyArray(m.x) # not enough, doesn't handle nesting


unmanage(x) = x

unmanage(m::Managed) = copy(m.x) # expensive fallback
unmanage(m::Managed{<:ReadOnly}) = copy(m.x.value) # expensive fallback

unmanage(m::Managed{<:Array}) = unmanage.(m.x)
unmanage(m::Managed{<:ReadOnly{T}}) where {T<:Array} = ReadOnlyArray(m.x.value)

unmanage(m::Managed{<:Dict}) = Dict(unmanage(k)=>unmanage(v) for (k,v) in m.x)
unmanage(m::Managed{<:Set}) = Set(unmanage(a) for a in m.x)

unmanage(m::Managed{<:Pair}) = unmanage(m.x.first)=>unmanage(m.x.second)
unmanage(m::Managed{<:Tuple}) = unmanage.(m.x)
unmanage(m::Managed{<:NamedTuple}) = map(unmanage, m.x)

# supported containers
Base.getindex(m::Managed{<:AbstractArray}, args...) =
	manage.(getindex(m.x, args...))
Base.getindex(m::Managed{<:Tuple}) =
	manage.(getindex(m.x, args...))
# TODO: more functions and support for pair, dict, set, namedtuple

