mutable struct SpecArgs # TODO: Add template parameters for args/kwargs? Or find a another way to handle types better?
	f::Any
	args::Tuple
	kwargs::NamedTuple
	function SpecArgs(f, args, kwargs)
		@assert issorted(keys(kwargs))
		new(f, args, kwargs)
	end
end

Base.:(==)(a::SpecArgs, b::SpecArgs) = a.f == b.f && a.args == b.args && a.kwargs == b.kwargs
Base.isequal(a::SpecArgs, b::SpecArgs) = isequal(a.f, b.f) && isequal(a.args, b.args) && isequal(a.kwargs, b.kwargs)

# deduplicate_type(::Deduplicator, ::Type{SpecArgs}) = true

Deduplicators.deduplicate_type(::Type{SpecArgs}) = true
Deduplicators.deduplication_pointer(sa::SpecArgs) = pointer_from_objref(sa)
function Deduplicators.deduplicate_children!(d, sa::SpecArgs; kwargs...)
	f = sa.f # TODO: Should this be processed somehow? Probably not.
	a = deduplicate!(d, sa.args; kwargs...)
	kw = deduplicate!(d, sa.kwargs; kwargs...)
	if f === sa.f && a === sa.args && kw === sa.kwargs
		sa # Not changed
	else
		SpecArgs(f, a, kw)
	end
end
function Deduplicators.deduplication_hash(d, sa::SpecArgs)
	# TODO: Could we make this more efficient? (Is it a problem? Probably not.)
	f = sa.f
	a = Deduplicators.deduplication_hash(d, sa.args)
	kw = Deduplicators.deduplication_hash(d, sa.kwargs)
	Deduplicators.compute_hash(d, (Deduplicators.TypeTag(:SpecArgs), f, a, kw))
end
Deduplicators.deduplication_copy(sa::SpecArgs) = sa



function Deduplicators.cache_save(io, name, spec::SpecArgs)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "SpecArgs"
	g["f"] = spec.f # Is this the best I can do?
	Deduplicators.cache_save(g, "args", spec.args)
	Deduplicators.cache_save(g, "kwargs", spec.kwargs)
	nothing
end
function Deduplicators.cache_load(cache::Cache, ::Val{:SpecArgs}, g)
	f = g["f"]
	args = Deduplicators.cache_load(cache, g, "args")
	kwargs = Deduplicators.cache_load(cache, g, "kwargs")
	sa = SpecArgs(f, args, kwargs)
	deduplicate!(cache.deduplicator, sa; transfer_ownership=true)
end

_get_kwarg(sa::SpecArgs, key::Symbol, default) = get(sa.kwargs, key, default)
_get_kwarg(f, sa::SpecArgs, key::Symbol) = get(f, sa.kwargs, key)
_get_kwarg(sa::SpecArgs, key::Symbol) = getindex(sa.kwargs, key)


abstract type AbstractSpecOp end

struct Call <: AbstractSpecOp end
struct Fetch <: AbstractSpecOp end # Means fetch immediately (e.g. get as value during preprocessing)
struct Prefetch <: AbstractSpecOp end # Replace spec by result just before computing - useful to collapse multiple specs that yield the same result onto the same spec.
struct Forward <: AbstractSpecOp end # Is this a good name?

Deduplicators.deduplicate_type(::Type{<:AbstractSpecOp}) = false
Deduplicators.deconstruct_weak_rec(x::T) where T<:AbstractSpecOp = x
Deduplicators.reconstruct_weak_rec(x::T) where T<:AbstractSpecOp = x

function Deduplicators.cache_save(io, name, x::AbstractSpecOp)
	# TODO: Do not save the structs as is, use either custom cache_save or custom_wrap.
	io[name] = x
	nothing
end



# Are these still needed?
forward(::Call) = Call()
forward(::Fetch) = Fetch()
forward(::Prefetch) = Prefetch()
forward(::Forward) = Forward()

default_spec_op() = Forward()


struct Spec
	sa::SpecArgs
	op::Union{Call,Fetch,Prefetch,Forward}
end
Spec(sa::SpecArgs) = Spec(sa, default_spec_op())

Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting
Base.Broadcast.broadcastable(sa::SpecArgs) = Ref(sa) # treat as scalar for broadcasting

# Usually accessed through getproperty
get_function(spec::Spec) = spec.sa.f
get_args(spec::Spec) = spec.sa.args
get_kwargs(spec::Spec) = spec.sa.kwargs


function Base.getproperty(spec::Spec, s::Symbol)
	s === :f && return get_function(spec)
	s === :args && return get_args(spec)
	s === :kwargs && return get_kwargs(spec)
	getfield(spec, s)
end
function Base.propertynames(s::Spec, private::Bool=false)
	n = (:f, :args, :kwargs)
	private ? (n..., fieldnames(Spec)...) : n
end


Deduplicators.deduplicate_type(::Type{Spec}) = true
Deduplicators.deconstruct_type(::Type{Spec}) = true
Deduplicators.type_to_tag(::Type{Spec}) = Deduplicators.TypeTag(:Spec)
Deduplicators.tag_to_type(::Val{:Spec}) = Spec
Deduplicators.deconstruct(spec::Spec) = (spec.sa, spec.op)
Deduplicators.reconstruct(::Type{Spec}, (sa,op)::Tuple{SpecArgs,<:Any}) = Spec(sa, op)




function create_spec(f, args...; deduplicator=default_deduplicator(), kwargs...)
	kw = values(kwargs)
	kw = NamedTuple{TupleTools.sort(keys(kw))}(kw) # sort by key
	sa = deduplicate!(deduplicator, SpecArgs(f, args, kw))
	spec = Spec(sa)

end


Base.:(==)(a::Spec, b::Spec) = a.op == b.op && a.sa == b.sa
Base.isequal(a::Spec, b::Spec) = isequal(a.op, b.op) && isequal(a.sa, b.sa)


_get_spec_args(spec::Spec) = spec.sa


# NB: To visit all dependencies of a spec, call visit_specs on spec.sa.
visit_specs(f, spec::Spec) = f(spec)

function visit_specs(f, sa::SpecArgs)
	visit_specs(f, sa.args)
	visit_specs(f, sa.kwargs)
end

function visit_specs(f, v::AbstractVector{T}) where T
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	Deduplicators._deduplicate_eltype(T) && visit_specs.(Ref(f), v)
end
function visit_specs(f, d::Dict{K,V}) where {K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	Deduplicators._deduplicate_eltype(K) && visit_specs.(Ref(f), keys(d))
	Deduplicators._deduplicate_eltype(V) && visit_specs.(Ref(f), values(d))
end

function visit_specs(f, nt::T) where T<:NamedTuple
	foreach(x->visit_specs(f,x), nt)
end

function visit_specs(f, df::DataFrame)
	foreach(col->visit_specs(f,col), eachcol(df)) # This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
end

function visit_specs(f, x::T) where T
	# @assert Deduplicators.deconstruct_type(T) "visit_specs fallback only available for types that can be deconstructed, got $T."
	if Deduplicators.deconstruct_type(T)
		xd = Deduplicators.deconstruct(x)::Tuple
		visit_specs.(Ref(f), xd)
	else
		# TODO: Should we have this fallback? Or define visit_specs for everything including Int, String, etc.
		x
	end
end



# NB: To map all dependencies of a spec, call map_specs on spec.sa.
map_specs(f, spec::Spec) = f(spec)

function map_specs(f, sa::SpecArgs)
	a = map_specs(f, sa.args)
	kw = map_specs(f, sa.kwargs)
	SpecArgs(sa.f, a, kw)
end

function map_specs(f, v::AbstractVector{T}) where T
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	if Deduplicators._deduplicate_eltype(T)
		ReadOnlyArray(map_specs.(Ref(f), v))
	else
		v # keep as is
	end
end
function map_specs(f, dict::Dict{K,V}) where {K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	replace_keys = Deduplicators._deduplicate_eltype(K)
	replace_values = Deduplicators._deduplicate_eltype(V)

	if dedup_keys && dedup_values
		Dict(map_specs(f, k)=>map_specs(f, v) for (k,v) in dict)
	elseif dedup_values
		Dict(k=>map_specs(f, v) for (k,v) in dict)
	elseif dedup_keys
		Dict(map_specs(f, k)=>v for (k,v) in dict)
	else
		dict
	end
end

function map_specs(f, nt::T) where T<:NamedTuple
	map(x->map_specs(f,x), nt)
end

function map_specs(f, df::DataFrame)
	# This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
	DataFrame((name=>map_specs(f,col) for (name,col) in pairs(eachcol(df)))...; copycols=false)
end

function map_specs(f, x::T) where T
	# @assert Deduplicators.deconstruct_type(T) "map_specs fallback only available for types that can be deconstructed, got $T."
	if Deduplicators.deconstruct_type(T)
		xd = Deduplicators.deconstruct(x)::Tuple
		xd = map(x->map_specs(f,x), xd)
		Deduplicators.reconstruct(T, xd)
	else
		# TODO: Should we have this fallback? Or define map_specs for everything including Int, String, etc.
		x
	end
end


fetched(spec::Spec) = Spec(spec.sa, Fetch())
prefetched(spec::Spec) = Spec(spec.sa, Prefetch())

fetched(x) = map_specs(fetched, x)
prefetched(x) = map_specs(prefetched, x)



# --- printing ---
function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, spec.f)
	else
		# print_spec_old(io, spec; maxdepth=20)
		print_spec(io, spec; maxdepth=20)
	end
end

Base.show(io::IO, ::Call) = print(io, "call")
Base.show(io::IO, ::Fetch) = print(io, "fetched")
Base.show(io::IO, ::Prefetch) = print(io, "prefetched")
Base.show(io::IO, ::Forward) = print(io, "forwarded")
