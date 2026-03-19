# abstract type AbstractSpecOp end

# struct Call <: AbstractSpecOp end
# struct Fetch <: AbstractSpecOp end # Means fetch immediately (e.g. get as value during preprocessing)
# struct Prefetch <: AbstractSpecOp end # Replace spec by result just before computing - useful to collapse multiple specs that yield the same result onto the same spec.
# struct Forward <: AbstractSpecOp end

# deduplicate_type(::Type{<:AbstractSpecOp}) = false
# deconstruct_weak_rec(x::T) where T<:AbstractSpecOp = x
# reconstruct_weak_rec(x::T) where T<:AbstractSpecOp = x

# function cache_save(io, name, x::AbstractSpecOp)
# 	io[name] = x # Rely on JLD2 standard handling for saving/loading
# 	nothing
# end


# default_spec_op() = Forward()




mutable struct SpecArgs # TODO: Add template parameters for args/kwargs? Or find a another way to handle types better?
	f::Any
	args::Tuple
	kwargs::NamedTuple

	# Cache (forwarding)
	# This is the result of `process_once`, when preprocessing.
	# Later, we might want to make this a sumtype. (But then we need mutually recursive types, which is not yet supported by Julia.)
	next::Any # NotValid means it is not computed. Most often a Spec. Can also be a value (in rare cases specs forwards to values).

	# In the rare case it is forwarded to a value, the value is wrapped in Some.
	# NB: The Tuple is just a way to store a `Spec` before Spec has been defined. When Julia supports mutually recursive types, we can use that instead.
	# next::Union{NotValid, Tuple{SpecArgs,Union{Call,Fetch,Prefetch,Forward}}, Some}

	# Cache (result)
	result::Any
	weak_result::Any

	function SpecArgs(f, args, kwargs)
		@assert issorted(keys(kwargs))
		new(f, args, kwargs, NotValid(), NotValid(), NotValid())
	end
end
SpecArgs(sa::SpecArgs) = sa

Base.propertynames(::SpecArgs, private::Bool=false) =
	private ? fieldnames(SpecArgs) : (:f, :args, :kwargs)



deduplicate_type(::Type{SpecArgs}) = true
deduplication_pointer(sa::SpecArgs) = pointer_from_objref(sa)
function deduplicate_children!(d, sa::SpecArgs; kwargs...)
	f = sa.f # TODO: Should this be processed somehow? Probably not.
	a = deduplicate!(d, sa.args; kwargs...)
	kw = deduplicate!(d, sa.kwargs; kwargs...)
	if f === sa.f && a === sa.args && kw === sa.kwargs
		sa # Not changed
	else
		SpecArgs(f, a, kw)
	end
end
function deduplication_hash(d, sa::SpecArgs)
	# TODO: Could we make this more efficient? (Is it a problem? Probably not.)
	f = sa.f
	a = deduplication_hash(d, sa.args)
	kw = deduplication_hash(d, sa.kwargs)
	compute_hash(d, (TypeTag(:SpecArgs), f, a, kw))
end
deduplication_copy(sa::SpecArgs) = sa



function cache_save(io, name, spec::SpecArgs)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "SpecArgs"
	g["f"] = spec.f # Is this the best I can do?
	cache_save(g, "args", spec.args)
	cache_save(g, "kwargs", spec.kwargs)
	nothing
end
function cache_load(cache::Cache, ::Val{:SpecArgs}, g)
	f = g["f"]
	args = cache_load(cache, g, "args")
	kwargs = cache_load(cache, g, "kwargs")
	sa = SpecArgs(f, args, kwargs)
	deduplicate!(cache.deduplicator, sa; transfer_ownership=true)
end




function sa_isequal(a::SpecArgs, b::SpecArgs)
	a === b && return true # early out
	isequal(a.f, b.f) && sa_isequal(a.args, b.args) && sa_isequal(a.kwargs, b.kwargs)
end

function sa_isequal(a::AbstractVector{T1}, b::AbstractVector{T2}) where {T1,T2}
	isequal(length(a), length(b)) || return false
	all(t->sa_isequal(t[1], t[2]), zip(a,b))
end

function sa_isequal(a::Dict{K1,V1}, b::Dict{K2,V2}) where {K1,V1,K2,V2}
	isequal(length(a), length(b)) || return false
    for pair in a
        in(pair, b, sa_isequal) || return false
    end
    true
end

sa_isequal(a::NamedTuple{n}, b::NamedTuple{n}) where n = sa_isequal(Tuple(a), Tuple(b))
sa_isequal(a::NamedTuple, b::NamedTuple) = false # keys are different

function sa_isequal(a::DataFrame, b::DataFrame)
	isequal(ncol(a), ncol(b)) || return false
	isequal(names(a), names(b)) || return false
	all(t->sa_isequal(t[1], t[2]), zip(eachcol(a),eachcol(b)))
end

function sa_isequal(a::T1, b::T2) where {T1,T2}
	if deconstruct_type(T1) && deconstruct_type(T2)
		ad = deconstruct(a)::Tuple
		bd = deconstruct(b)::Tuple

		isequal(length(ad), length(bd)) || return false
		all(t->sa_isequal(t[1], t[2]), zip(ad,bd))
	else
		# TODO: Should we have this fallback?
		isequal(a,b)
	end
end

Base.isequal(a::SpecArgs, b::SpecArgs) = sa_isequal(a, b)




_get_kwarg(sa::SpecArgs, key::Symbol, default) = get(sa.kwargs, key, default)
_get_kwarg(f, sa::SpecArgs, key::Symbol) = get(f, sa.kwargs, key)
_get_kwarg(sa::SpecArgs, key::Symbol) = getindex(sa.kwargs, key)


# TODO: Make this code easier to read
function get_next!(f, sa::SpecArgs)
	if sa.next === NotValid()
		sa.next = f()
	end
	sa.next
end

# TODO: Make this code easier to read
function get_result!(f, sa::SpecArgs)
	sa.result !== NotValid() && return sa.result

	if sa.weak_result !== NotValid()
		# Attempt to reconstruct from weakly stored reference
		sa.result = reconstruct_weak_rec(sa.weak_result)
		sa.result !== NotValid() && return sa.result
	end

	# Compute result
	sa.result = f()
	sa.weak_result = deconstruct_weak_rec(sa.result)
	return sa.result
end

# NB: Any weak result will still be present and the result can thus still be reconstructed if it has not yet been GCed.
empty_result!(sa::SpecArgs) = (sa.result = NotValid(); sa)



function try_get_result_rec(spec::SpecUnion)
	sa = get_sa(spec)
	if sa.result !== NotValid() || sa.weak_result !== NotValid()
		sa.result, sa.weak_result
	elseif sa.next !== NotValid()
		if sa.next isa SpecUnion
			try_get_result_rec(sa.next) # recurse
		else
			sa.next, NotValid() # it forwarded to a value
		end
	else
		NotValid(), NotValid()
	end
end




Base.Broadcast.broadcastable(sa::SpecArgs) = Ref(sa) # treat as scalar for broadcasting



abstract type WrappedSpec end

struct Call <: WrappedSpec
	sa::SpecArgs
end
struct Fetch <: WrappedSpec
	sa::SpecArgs
end
struct Prefetch <: WrappedSpec
	sa::SpecArgs
end

Base.Broadcast.broadcastable(ws::WrappedSpec) = Ref(ws) # treat as scalar for broadcasting


const SpecUnion = Union{SpecArgs, Call, Fetch, Prefetch}



# # struct Spec
# # 	sa::SpecArgs
# # 	op::Union{Call,Fetch,Prefetch,Forward}
# # end
# # Spec(sa::SpecArgs) = Spec(sa, default_spec_op())

# Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting

# Usually accessed through getproperty
get_function(ws::WrappedSpec) = ws.sa.f
get_args(ws::WrappedSpec) = ws.sa.args
get_kwargs(ws::WrappedSpec) = ws.sa.kwargs

function Base.getproperty(ws::WrappedSpec, s::Symbol)
	s === :f && return get_function(ws)
	s === :args && return get_args(ws)
	s === :kwargs && return get_kwargs(ws)
	getfield(ws, s)
end
Base.propertynames(::WrappedSpec, private::Bool=false) =
	private ? (:f, :args, :kwargs, :sa) : (:f, :args, :kwargs)


# TODO: Rename to get_spec?
get_sa(sa::SpecArgs) = sa
get_sa(ws::WrappedSpec) = ws.sa

SpecArgs(ws::WrappedSpec) = get_sa(ws)




function transfer_op(::S, dest::D) where {D<:SpecUnion, S<:SpecUnion}
	if S === Call
		D === Call ? dest : get_sa(dest) # We can keep Call, but never transfer it (so fallback to standard forwarding)
	else
		S(get_sa(dest)) # Transfer
	end
end




deduplicate_type(::Type{<:WrappedSpec}) = true
deconstruct_type(::Type{<:WrappedSpec}) = true
type_to_tag(::Type{Call}) = TypeTag(:Call)
type_to_tag(::Type{Fetch}) = TypeTag(:Fetch)
type_to_tag(::Type{Prefetch}) = TypeTag(:Prefetch)
tag_to_type(::Val{:Call}) = Call
tag_to_type(::Val{:Fetch}) = Fetch
tag_to_type(::Val{:Prefetch}) = Prefetch
deconstruct(ws::WrappedSpec) = (ws.sa,)
reconstruct(::Type{T}, (sa,)::Tuple{SpecArgs}) where T<:WrappedSpec = T(sa)




function create_spec(f, args...; scheduler=get_scheduler(), deduplicator=scheduler.deduplicator, kwargs...)
	kw = values(kwargs)
	kw = sort_namedtuple_by_keys(kw)
	sa = SpecArgs(f, args, kw)
	deduplicator !== nothing && (sa = deduplicate!(deduplicator, sa))
	sa
	# spec = Spec(sa)
end


# Base.isequal(a::Spec, b::Spec) = isequal(a.op, b.op) && isequal(a.sa, b.sa)
Base.isequal(::WrappedSpec, ::WrappedSpec) = false # different wrappers
Base.isequal(a::T, b::T) where T<:WrappedSpec = isequal(a.sa, b.sa)


_get_spec_args(ws::WrappedSpec) = ws.sa



function visit_dependencies(f, sa::SpecArgs)
	visit_specs(f, sa.args)
	visit_specs(f, sa.kwargs)
end
# visit_dependencies(f, ws::WrappedSpec) = visit_dependencies(f, ws.sa)


# NB: To visit all dependencies of a spec, call visit_dependencies on sa.
visit_specs(f, sa::SpecArgs) = f(sa)
visit_specs(f, ws::WrappedSpec) = f(ws)

# function visit_specs(f, sa::SpecArgs)
# 	visit_specs(f, sa.args)
# 	visit_specs(f, sa.kwargs)
# end

function visit_specs(f, v::AbstractVector{T}) where T
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	_deduplicate_eltype(T) && visit_specs.(Ref(f), v)
end
function visit_specs(f, d::Dict{K,V}) where {K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	_deduplicate_eltype(K) && visit_specs.(Ref(f), keys(d))
	_deduplicate_eltype(V) && visit_specs.(Ref(f), values(d))
end

function visit_specs(f, nt::T) where T<:NamedTuple
	foreach(x->visit_specs(f,x), nt)
end

function visit_specs(f, df::DataFrame)
	foreach(col->visit_specs(f,col), eachcol(df)) # This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
end

function visit_specs(f, x::T) where T
	# @assert deconstruct_type(T) "visit_specs fallback only available for types that can be deconstructed, got $T."
	if deconstruct_type(T)
		xd = deconstruct(x)::Tuple
		visit_specs.(Ref(f), xd)
	else
		# TODO: Should we have this fallback? Or define visit_specs for everything including Int, String, etc.
		x
	end
end


# Find a better name?
function map_args(f::F, sa::SpecArgs) where F
	a = map_specs(f, sa.args)
	kw = map_specs(f, sa.kwargs)
	SpecArgs(sa.f, a, kw)
end


# Find a better name?
# NB: To map all args/dependencies of a spec, call map_args on sa.
map_specs(f::F, sa::SpecArgs) where F = @something f(sa) sa
map_specs(f::F, ws::WrappedSpec) where F = @something f(ws) ws

function _map_specs(f::F, v::AbstractVector{T}) where {F,T}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	if _deduplicate_eltype(T)
		ReadOnlyArray(map_specs.(Ref(f), v))
	else
		v # keep as is
	end
end
map_specs(f::F, v::AbstractVector{T}) where {F,T} = @something f(v) _map_specs(f, v)

function _map_specs(f::F, dict::Dict{K,V}) where {F,K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	replace_keys = _deduplicate_eltype(K)
	replace_values = _deduplicate_eltype(V)

	if replace_keys && replace_values
		Dict(map_specs(f, k)=>map_specs(f, v) for (k,v) in dict)
	elseif replace_values
		Dict(k=>map_specs(f, v) for (k,v) in dict)
	elseif replace_keys
		Dict(map_specs(f, k)=>v for (k,v) in dict)
	else
		dict
	end
end
map_specs(f::F, dict::Dict{K,V}) where {F,K,V} = @something f(dict) _map_specs(f, dict)

map_specs(f::F, nt::T) where {F,T<:NamedTuple} =
	@something f(nt) map(x->map_specs(f,x), nt)

function map_specs(f::F, df::DataFrame) where F
	# This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
	@something f(df) DataFrame((name=>map_specs(f,col) for (name,col) in pairs(eachcol(df)))...; copycols=false)
end

function _map_specs(f::F, x::T) where {F,T}
	# @assert deconstruct_type(T) "map_specs fallback only available for types that can be deconstructed, got $T."
	if deconstruct_type(T)
		xd = deconstruct(x)::Tuple
		xd = map(x->map_specs(f,x), xd)
		reconstruct(T, xd)
	else
		# TODO: Should we have this fallback? Or define map_specs for everything including Int, String, etc.
		x
	end
end
map_specs(f::F, x::T) where {F,T} = @something f(x) _map_specs(f, x)


# _fetched(::Any) = nothing
# _fetched(spec::Spec) = Spec(spec.sa, Fetch())

# _prefetched(::Any) = nothing
# _prefetched(spec::Spec) = Spec(spec.sa, Prefetch())

# fetched(x) = map_specs(_fetched, x)
# prefetched(x) = map_specs(_prefetched, x)

_fetched(::Any) = nothing
_fetched(ws::WrappedSpec) = Fetch(ws.sa)
_fetched(sa::SpecArgs) = Fetch(sa)

_prefetched(::Any) = nothing
_prefetched(ws::WrappedSpec) = Prefetch(ws.sa)
_prefetched(sa::SpecArgs) = Prefetch(sa)

fetched(x) = map_specs(_fetched, x)
prefetched(x) = map_specs(_prefetched, x)



# --- printing ---
function Base.show(io::IO, spec::SpecUnion)
	if get(io,:compact,false)
		show(io, spec.f)
	else
		print_spec(io, spec; maxdepth=20)
		result, weak_result = try_get_result_rec(spec)

		if result !== NotValid()
			print(io, "Result: ")
			show(IOContext(io, :compact => true), result)
		elseif weak_result !== NotValid()
			print(io, "Result: ")
			show(IOContext(io, :compact => true), weak_result)
		end
	end
end

# Base.show(io::IO, ::Call) = print(io, "call")
# Base.show(io::IO, ::Fetch) = print(io, "fetched")
# Base.show(io::IO, ::Prefetch) = print(io, "prefetched")
# Base.show(io::IO, ::Forward) = print(io, "forwarded")
