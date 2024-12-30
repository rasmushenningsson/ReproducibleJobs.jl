"""
	Managed{T}

Wrapper containing a single object of type `T`.
Objects wrapped in `Managed` are read-only objects internal to `CacheBySpec`.
To access the contents, use `unmanage`. For `Vector`s, `Dict`s etc. children can be accessed using `getindex` and `get`.

See also: [`unmanage`](@ref)
"""
struct Managed{T}
	x::T
end

# TODO: Do we need to implement hash/== by forwarding somehow?

manage(x) = Managed(x)
manage(x::Managed) = x

# Basic immutable types - should this list be extended?
manage(x::Union{Number,String,Symbol,Nothing,Missing}) = x


"""
	unsafe_unmanage(m::Managed)

Retrieve the object wrapped in a `Managed`.

!!! note
	This is unsafe to use since it is up to the caller to ensure that the object and all nested objects within never get modified.

See also: [`unmanage`](@ref)
"""
unsafe_unmanage(m::Managed) = m.x
unsafe_unmanage(x) = x


# Recursive unmanaging

unmanage_rec(x) = copy(x) # expensive fallback
unmanage_rec(x::ReadOnly) = copy(x.value) # expensive fallback

unmanage_rec(x::Union{String,Symbol}) = x # doesn't define copy

unmanage_rec(x::Array) = unmanage_rec.(x)
unmanage_rec(x::ReadOnly{<:Array}) = ReadOnlyArray(x.value)

unmanage_rec(x::Dict) = Dict(unmanage_rec(k)=>unmanage_rec(v) for (k,v) in x)
unmanage_rec(x::Set) = Set(unmanage_rec(a) for a in x)
# TODO: ReadOnlyDict and ReadOnlySet if stored in ReadOnly

unmanage_rec(x::Pair) = unmanage_rec(x.first)=>unmanage_rec(x.second)
unmanage_rec(x::Tuple) = unmanage_rec.(x)
unmanage_rec(x::NamedTuple) = map(unmanage_rec, x)


"""
	unmanage(m::Managed)

Retrieve the contents of a `Managed` object.
In many cases, a read-only object will be returned, e.g. a `ReadOnlyArray`.
When this isn't possible, a copy of the object is made.

"""
unmanage(m::Managed) = unmanage_rec(m.x)



copy_arg(m::Managed) = m.x # Already managed, just unwrap



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
