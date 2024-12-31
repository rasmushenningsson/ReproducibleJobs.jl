# Wrapper struct used for access only
struct KwargVector <: AbstractVector{Pair{Symbol,Any}}
	kwargs::Vector{Pair{Symbol,Any}}
end

manage(v::KwargVector) = v # Already managed

function _get_kwarg_index(v::KwargVector, name::Symbol)
	r = searchsorted(v.kwargs, name=>nothing; by=first)
	isempty(r) && return nothing
	only(r)
end

function _get_kwarg(f, v::KwargVector, name::Symbol)
	i = _get_kwarg_index(v, name)
	i === nothing ? f() : last(v.kwargs[i])
end
_get_kwarg(v::KwargVector, name::Symbol) = _get_kwarg(()->throw(KeyError(name)), v, name)
_get_kwarg(v::KwargVector, name::Symbol, default) = _get_kwarg(Returns(default), v, name)

Base.IndexStyle(::Type{KwargVector}) = IndexLinear()
Base.size(v::KwargVector, args...) = size(v.kwargs, args...)

# NB: Other cases are handled automatically by AbstractArray fallbacks
function Base.getindex(v::KwargVector, i::Integer)
	p = v.kwargs[i]
	p.first => manage(p.second)
end

# Handle symbols to lookup kwargs
Base.getindex(v::KwargVector, s::Symbol) = manage(_get_kwarg(v,s))
Base.getindex(v::KwargVector, ind::Union{AbstractArray{Symbol},NTuple{<:Any,Symbol}}) =
	manage((; (s=>_get_kwarg(v,s) for s in ind)...))

Base.firstindex(v::KwargVector) = firstindex(v.kwargs)
Base.lastindex(v::KwargVector) = lastindex(v.kwargs)

function Base.iterate(v::KwargVector, args...)
	res = iterate(v.kwargs, args...)
	res === nothing && return nothing
	p, state = res
	p.first=>manage(p.second), state
end
