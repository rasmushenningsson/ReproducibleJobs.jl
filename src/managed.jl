struct Managed{T}
	x::T
end

# TODO: Do we need to implement hash/== by forwarding somehow?

manage(x) = Managed(x)
manage(x::Managed) = x

# Basic immutable types - should this list be extended?
manage(x::Union{Number,String,Symbol,Nothing,Missing}) = x


# Anyone using this must treat the object (and any nested objects within) as read-only
unsafe_unmanage(m::Managed) = m.x


unmanage(x) = x

unmanage(m::Managed) = copy(m.x) # expensive fallback
unmanage(m::Managed{<:ReadOnly}) = copy(m.x.value) # expensive fallback

unmanage(m::Managed{<:Array}) = unmanage.(m.x)
unmanage(m::Managed{<:ReadOnly{T}}) where {T<:Array} = ReadOnlyArray(m.x.value)

unmanage(m::Managed{<:Dict}) = Dict(unmanage(k)=>unmanage(v) for (k,v) in m.x)
unmanage(m::Managed{<:Set}) = Set(unmanage(a) for a in m.x)
# TODO: ReadOnlyDict and ReadOnlySet if stored in ReadOnly

unmanage(m::Managed{<:Pair}) = unmanage(m.x.first)=>unmanage(m.x.second)
unmanage(m::Managed{<:Tuple}) = unmanage.(m.x)
unmanage(m::Managed{<:NamedTuple}) = map(unmanage, m.x)

# Getters that wrap items as they are returned
Base.getindex(m::Managed{<:Union{Array,Dict,Pair,Tuple,NamedTuple}}, args...) =
	manage.(getindex(m.x, args...))
Base.get(m::Managed{<:Union{Array,Dict,Tuple,NamedTuple}}, args...) =
	manage.(get(m.x, args...))

Base.getindex(m::Managed{<:ReadOnly{T}}, args...) where {T<:Union{Array,Dict}} =
	getindex(m.x.value, args...)
Base.get(m::Managed{<:ReadOnly{T}}, args...) where {T<:Union{Array,Dict}} =
	get(m.x.value, args...)

# Forward array/dict stuff
Base.length(m::Managed{<:T}) where {T<:Union{Array,Dict,Set,Pair,Tuple,NamedTuple}} = length(m.x)
Base.length(m::Managed{<:ReadOnly{T}}) where {T<:Union{Array,Dict,Set}} = length(m.x.value)

Base.size(m::Managed{<:Array}, args...) = size(m.x, args...)
Base.size(m::Managed{<:ReadOnly{<:Array}}, args...) = size(m.x.value, args...)

Base.firstindex(m::Managed{<:T}) where {T<:Union{Array,Pair,Tuple,NamedTuple}} = firstindex(m.x)
Base.firstindex(m::Managed{<:ReadOnly{<:Array}}) = firstindex(m.x.value)
Base.lastindex(m::Managed{<:T}) where {T<:Union{Array,Pair,Tuple,NamedTuple}} = lastindex(m.x)
Base.lastindex(m::Managed{<:ReadOnly{<:Array}}) = lastindex(m.x.value)

Base.keys(m::Managed{<:T}) where {T<:Union{Array,Pair,Tuple,NamedTuple}} = keys(m.x)
Base.keys(m::Managed{<:ReadOnly{<:Array}}) = keys(m.x.value)

# The keys in a Dict might be managed, so we need to call manage here.
Base.keys(m::Managed{<:Dict}) = manage.(keys(m.x))
Base.keys(m::Managed{<:ReadOnly{<:Dict}}) = manage.(keys(m.x.value))
