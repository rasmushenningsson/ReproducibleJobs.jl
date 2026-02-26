mutable struct SpecArgs # Add template parameters for args/kwargs?
	f::Any
	args::ROVec # ROVec{Any}
	kwargs::ROVec # ROVec{Pair{Symbol,Any}}
	function SpecArgs(f, args, kwargs)
		@assert issorted(kwargs; by=first)
		new(f, args, kwargs)
	end
end

Base.:(==)(a::SpecArgs, b::SpecArgs) = a.f == b.f && a.args == b.args && a.kwargs == b.kwargs
Base.isequal(a::SpecArgs, b::SpecArgs) = isequal(a.f, b.f) && isequal(a.args, b.args) && isequal(a.kwargs, b.kwargs)

# deduplicate_type(::Deduplicator, ::Type{SpecArgs}) = true

Deduplicators.deduplicate_type(::Type{SpecArgs}) = true
Deduplicators.deduplication_pointer(sa::SpecArgs) = pointer_from_objref(sa)
function Deduplicators.deduplicate_children!(d, sa::SpecArgs; kwargs...)
	f = sa.f # TODO: Should this be processed somehow?
	a = deduplicate!(d, sa.args; kwargs...)
	kw = deduplicate!(d, sa.kwargs; kwargs...)
	if f === sa.f && a === sa.args && kw == sa.kwargs
		sa # Not changed
	else
		SpecArgs(f, a, kw)
	end
end
function Deduplicators.deduplication_hash(d, sa::SpecArgs)
	f = sa.f
	a = Deduplicators.lookup_hash(d, parent(sa.args))
	@assert a !== nothing # Deduplication of args will be done before this, so we can assume it is !== nothing
	kw = Deduplicators.lookup_hash(d, parent(sa.kwargs))
	@assert kw !== nothing # Deduplication of kwargs will be done before this, so we can assume it is !== nothing
	Deduplicators.compute_hash(d, (Deduplicators.TypeTag(:SpecArgs), f, a, kw))
end
Deduplicators.deduplication_copy(sa::SpecArgs) = sa



# function create_spec_args(p, f, args, kwargs)
# 	a = Any[copy_nested(p,x) for x in args]
# 	kw = sort!(Pair{Symbol,Any}[k=>copy_nested(p,v) for (k,v) in kwargs]; by=first)
# 	SpecArgs(f, ReadOnlyVector(a), ReadOnlyVector(kw))
# end



function _get_kwarg_index(kwargs::ROVec{T}, name::Symbol) where T
	r = searchsorted(kwargs, name=>nothing; by=first)
	isempty(r) && return nothing
	only(r)
end

function _get_kwarg(f, kwargs::ROVec{T}, name::Symbol) where T
	i = _get_kwarg_index(kwargs, name)
	i === nothing ? f() : last(kwargs[i])
end
_get_kwarg(kwargs::ROVec{T}, name::Symbol, default) where T =
	_get_kwarg(Returns(default), kwargs, name)
_get_kwarg(kwargs::ROVec{T}, name::Symbol) where T =
	_get_kwarg(()->throw(KeyError(name)), kwargs, name)


_get_kwarg(sa::SpecArgs, args...) = _get_kwarg(sa.kwargs, args...)
_get_kwarg(f, sa::SpecArgs) = _get_kwarg(f, sa.kwargs)


abstract type AbstractSpecOp end

struct Call <: AbstractSpecOp end
struct Fetch <: AbstractSpecOp end # Means fetch immediately (e.g. get as value during preprocessing)
struct Prefetch <: AbstractSpecOp end # Replace spec by result just before computing - useful to collapse multiple specs that yield the same result onto the same spec.
struct Forward <: AbstractSpecOp end # Is this a good name?

Deduplicators.deduplicate_type(::Type{<:AbstractSpecOp}) = false
Deduplicators.deconstruct_weak_rec(x::T) where T<:AbstractSpecOp = x
Deduplicators.reconstruct_weak_rec(x::T) where T<:AbstractSpecOp = x


# Are these still needed?
forward(::Call) = Call()
forward(::Fetch) = Fetch()
forward(::Prefetch) = Prefetch()
forward(::Forward) = Forward()

default_spec_op() = Forward()


struct Spec
	# ro::ReadOnly{SpecArgs}
	sa::SpecArgs
	# op::Any # Call/Fetch/Prefetch/Forward - is it better to use a Union? (Or a sum type?)
	op::Union{Call,Fetch,Prefetch,Forward}
end
Spec(sa::SpecArgs) = Spec(sa, default_spec_op())

Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting
Base.Broadcast.broadcastable(sa::SpecArgs) = Ref(sa) # treat as scalar for broadcasting

# # Usually accessed through getproperty
# get_versioned_function(spec::Spec) = _get_spec_args(spec).f
# get_args(spec::Spec) = manage(_get_spec_args(spec).args)
# get_kwargs(spec::Spec) = KwargVector(_get_spec_args(spec).kwargs)

# Usually accessed through getproperty
get_function(spec::Spec) = spec.sa.f
get_args(spec::Spec) = spec.sa.args
get_kwargs(spec::Spec) = KwargVector(spec.sa.kwargs)


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


# deduplicate_type(::Deduplicator, ::Type{Spec}) = false

Deduplicators.deduplicate_type(::Type{Spec}) = true
Deduplicators.deconstruct_type(::Type{Spec}) = true
Deduplicators.type_to_tag(::Type{Spec}) = Deduplicators.TypeTag(:Spec)
Deduplicators.tag_to_type(::Val{:Spec}) = Spec
Deduplicators.deconstruct(spec::Spec) = (spec.sa, spec.op)
Deduplicators.reconstruct(::Type{Spec}, (sa,op)::Tuple{SpecArgs,<:Any}) = Spec(sa, op)



# _is_leaf_type(::Type{Spec}) = false
# copy_arg(spec::Spec) = spec # Already managed, no need to copy
# # copy_arg(ro::ReadOnly{SpecArgs}) = Spec(ro, nothing) # Wrap in Spec



# manage(spec::Spec) = spec # Already managed

function create_spec(f, args...; deduplicator=default_deduplicator(), kwargs...)
	# a = deduplicate!(deduplicator, collect(args))
	# kw = deduplicate!(deduplicator, collect(kwargs))
	a = deduplicate!(deduplicator, isempty(args) ? [] : collect(args)) # Use Any as eltype if no args

	# kw = deduplicate!(deduplicator, isempty(kwargs) ? [] : collect(kwargs)) # Use Any as eltype if no kwargs
	kw = isempty(kwargs) ? [] : sort!(collect(kwargs); by=first) # Use Any as eltype if no kwargs
	kw = deduplicate!(deduplicator, kw)
	sa = deduplicate!(deduplicator, SpecArgs(f, a, kw))
	spec = Spec(sa)

	# sa = SpecArgs(f, ReadOnlyArray(collect(Any, args)), ReadOnlyArray(collect(Pair{Symbol,Any}, kwargs)))
	# spec = Spec(sa)
	# deduplicate!(deduplicator, spec)

	# p = deduplicate_leaves(deduplicator)∘copy_arg
	# sa = create_spec_args(p, f, args, kwargs)
	# sa = deduplicator(sa)
	# Spec(sa)
end



# Base.:(==)(a::Spec, b::Spec) = a.op == b.op && a.ro == b.ro
Base.:(==)(a::Spec, b::Spec) = a.op == b.op && a.sa == b.sa
Base.isequal(a::Spec, b::Spec) = isequal(a.op, b.op) && isequal(a.sa, b.sa)


_get_spec_args(spec::Spec) = spec.sa

# get_hash(spec::Spec) = get_hash(spec.ro)



# Can/should we implement visit_dependencies in a more general fashion? (So that custom, non-destructable, user types do not need to add methods.)

# visit_dependencies(f, spec::Spec) = _visit_dependencies(f, spec.sa)
_visit_dependencies(f, spec::Spec) = f(spec)

function visit_dependencies(f, sa::SpecArgs)
	_visit_dependencies(f, sa.args)
	_visit_dependencies(f, sa.kwargs)
end

function _visit_dependencies(f, v::AbstractVector{T}) where T
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	Deduplicators._deduplicate_eltype(T) && _visit_dependencies.(Ref(f), v)
end
function _visit_dependencies(f, d::Dict{K,V}) where {K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	Deduplicators._deduplicate_eltype(K) && _visit_dependencies.(Ref(f), keys(d))
	Deduplicators._deduplicate_eltype(V) && _visit_dependencies.(Ref(f), values(d))
end

function _visit_dependencies(f, nt::T) where T<:NamedTuple
	foreach(x->visit_dependencies(f,x), nt)
end

function _visit_dependencies(f, df::DataFrame)
	foreach(col->visit_dependencies(f,col), eachcol(df)) # This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
end

function _visit_dependencies(f, x::T) where T
	# @assert Deduplicators.deconstruct_type(T) "_visit_dependencies fallback only available for types that can be deconstructed, got $T."
	if Deduplicators.deconstruct_type(T)
		xd = Deduplicators.deconstruct(x)::Tuple
		_visit_dependencies.(Ref(f), xd)
	else
		# TODO: Should we have this fallback? Or define _visit_dependencies for everything including Int, String, etc.
		x
	end
end


# Can/should we implement replace_dependencies in a more general fashion? (So that custom, non-destructable, user types do not need to add methods.)

_replace_dependencies(upstream, spec::Spec) = get(upstream, spec, spec)

function replace_dependencies(upstream, sa::SpecArgs)
	a = _replace_dependencies(upstream, sa.args)
	kw = _replace_dependencies(upstream, sa.kwargs)
	SpecArgs(sa.f, a, kw)
end

function _replace_dependencies(upstream, v::AbstractVector{T}) where T
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	if Deduplicators._deduplicate_eltype(T)
		ReadOnlyArray(_replace_dependencies.(Ref(upstream), v))
	else
		v # keep as is
	end
end
function _replace_dependencies(upstream, dict::Dict{K,V}) where {K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	replace_keys = Deduplicators._deduplicate_eltype(K)
	replace_values = Deduplicators._deduplicate_eltype(V)

	if dedup_keys && dedup_values
		Dict(_replace_dependencies(upstream, k)=>_replace_dependencies(upstream, v) for (k,v) in dict)
	elseif dedup_values
		Dict(k=>_replace_dependencies(upstream, v) for (k,v) in dict)
	elseif dedup_keys
		Dict(_replace_dependencies(upstream, k)=>v for (k,v) in dict)
	else
		dict
	end
end

function _replace_dependencies(upstream, nt::T) where T<:NamedTuple
	map(x->_replace_dependencies(upstream,x), nt)
end

function _replace_dependencies(upstream, df::DataFrame)
	map(col->_replace_dependencies(upstream,col), eachcol(df)) # This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
end

function _replace_dependencies(upstream, x::T) where T
	# @assert Deduplicators.deconstruct_type(T) "_replace_dependencies fallback only available for types that can be deconstructed, got $T."
	if Deduplicators.deconstruct_type(T)
		xd = Deduplicators.deconstruct(x)::Tuple
		xd = map(x->_replace_dependencies(upstream,x), xd)
		Deduplicators.reconstruct(T, xd)
	else
		# TODO: Should we have this fallback? Or define _replace_dependencies for everything including Int, String, etc.
		x
	end
end




# # TODO: Use predicate version for smart early-outs?
# function visit_dependencies(f, v::Vector)
# 	visit_nested(v) do x
# 		x isa Spec && f(x)
# 	end
# end
# function visit_dependencies(f, sa::SpecArgs)
# 	visit_dependencies(f, sa.args)
# 	visit_dependencies(f, sa.kwargs)
# end
# visit_dependencies(f, spec::Spec) = visit_dependencies(f, _get_spec_args(spec))



# deduplicate!(dedup::Deduplicator, spec::Spec) = Spec(deduplicate!(dedup, spec.ro), spec.op)



# # Are these still needed?
# forwarded(spec::Spec) = Spec(spec.ro, forward(spec.op))
# forwarded(x) = x



# _fetched(spec::Spec) = Spec(spec.ro, Fetch())
# _fetched(x) = x
# fetched(x::Any) = copy_nested(_fetched, x)

# _prefetched(spec::Spec) = Spec(spec.ro, Prefetch())
# _prefetched(x) = x
# prefetched(x::Any) = copy_nested(_prefetched, x)

fetched(spec::Spec) = Spec(spec.sa, Fetch())
prefetched(spec::Spec) = Spec(spec.sa, Prefetch())


# --- printing ---
# function Base.show(io::IO, spec::Spec)
# 	if get(io,:compact,false)
# 		show(io, spec.f)
# 	else
# 		# print_spec_old(io, spec; maxdepth=20)
# 		print_spec(io, spec; maxdepth=20)
# 	end
# end

Base.show(io::IO, ::Call) = print(io, "call")
Base.show(io::IO, ::Fetch) = print(io, "fetched")
Base.show(io::IO, ::Prefetch) = print(io, "prefetched")
Base.show(io::IO, ::Forward) = print(io, "forwarded")
