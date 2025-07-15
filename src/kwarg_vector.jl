# Wrapper struct used for access only
struct KwargVector <: AbstractVector{Pair{Symbol,Any}}
	kwargs::Vector{Pair{Symbol,Any}}
end

manage(v::KwargVector) = v # Already managed

# Is this implementation what we want, or should we have a type param to KwargVector deciding if it's managed or not?
# Would make more sense for unsafe_unmanage to return an object of the same type...
unsafe_unmanage(v::KwargVector) = v.kwargs


_get_kwarg_index(v::KwargVector, name::Symbol) = _get_kwarg_index(v.kwargs, name)

Base.get(f, v::KwargVector, name::Symbol) =
	_get_kwarg(f, v.kwargs, name)
Base.get(v::KwargVector, name::Symbol, default) =
	_get_kwarg(v.kwargs, name, default)

Base.IndexStyle(::Type{KwargVector}) = IndexLinear()
Base.size(v::KwargVector, args...) = size(v.kwargs, args...)

# NB: Other cases are handled automatically by AbstractArray fallbacks
function Base.getindex(v::KwargVector, i::Integer)
	p = v.kwargs[i]
	p.first => manage(p.second)
end

# Handle symbols to lookup kwargs
Base.getindex(v::KwargVector, s::Symbol) = manage(get(()->throw(KeyError(s)), v, s))
Base.getindex(v::KwargVector, ind::Union{AbstractArray{Symbol},NTuple{<:Any,Symbol}}) =
	manage((; (s=>v[s] for s in ind)...))

Base.firstindex(v::KwargVector) = firstindex(v.kwargs)
Base.lastindex(v::KwargVector) = lastindex(v.kwargs)

function Base.iterate(v::KwargVector, args...)
	res = iterate(v.kwargs, args...)
	res === nothing && return nothing
	p, state = res
	p.first=>manage(p.second), state
end
