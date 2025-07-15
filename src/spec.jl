struct SpecArgs
	f::Any # Hm. Can this just be Symbol now?
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
	function SpecArgs(f, args, kwargs)
		@assert issorted(kwargs; by=first)
		new(f, args, kwargs)
	end
end

Base.:(==)(a::SpecArgs, b::SpecArgs) = a.f == b.f && a.args == b.args && a.kwargs == b.kwargs

deduplicate_type(::Deduplicator, ::Type{SpecArgs}) = true

function create_spec_args(p, f, args, kwargs)
	a = Any[copy_nested(p,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[k=>copy_nested(p,v) for (k,v) in kwargs]; by=first)
	SpecArgs(f,a,kw)
end



function _get_kwarg_index(kwargs::Vector{Pair{Symbol,Any}}, name::Symbol)
	r = searchsorted(kwargs, name=>nothing; by=first)
	isempty(r) && return nothing
	only(r)
end

function _get_kwarg(f, kwargs::Vector{Pair{Symbol,Any}}, name::Symbol)
	i = _get_kwarg_index(kwargs, name)
	i === nothing ? f() : last(kwargs[i])
end
_get_kwarg(kwargs::Vector{Pair{Symbol,Any}}, name::Symbol, default) =
	_get_kwarg(Returns(default), kwargs, name)
_get_kwarg(kwargs::Vector{Pair{Symbol,Any}}, name::Symbol) =
	_get_kwarg(()->throw(KeyError(name)), kwargs, name)


_get_kwarg(sa::SpecArgs, args...) = _get_kwarg(sa.kwargs, args...)
_get_kwarg(f, sa::SpecArgs) = _get_kwarg(f, sa.kwargs)



struct Call end
struct Prefetch end # Rename?
struct Forward{F} # Rename to something that would indicate that we should stop if predicate is true?
	predicate::F # true means we found what we want, so forwarding will stop
end
Forward() = Forward(Returns(false))


forward(::Call) = Call()
forward(::Prefetch) = Prefetch()
forward(::Forward) = Forward() # get rid of the predicate
forward(::Nothing) = Forward()



struct Spec
	ro::ReadOnly{SpecArgs}
	op::Any # Call/Prefetch/Forward{F}/Nothing - is it better to use a Union?
end

Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting
Base.Broadcast.broadcastable(sa::SpecArgs) = Ref(sa) # treat as scalar for broadcasting

# Usually accessed through getproperty
get_versioned_function(spec::Spec) = _get_spec_args(spec).f
get_args(spec::Spec) = manage(_get_spec_args(spec).args)
get_kwargs(spec::Spec) = KwargVector(_get_spec_args(spec).kwargs)


function Base.getproperty(spec::Spec, s::Symbol)
	s === :f && return get_versioned_function(spec)
	s === :args && return get_args(spec)
	s === :kwargs && return get_kwargs(spec)
	getfield(spec, s)
end
function Base.propertynames(s::Spec, private::Bool=false)
	n = (:f, :args, :kwargs)
	private ? (n..., fieldnames(Spec)...) : n
end


deduplicate_type(::Deduplicator, ::Type{Spec}) = false

_is_leaf_type(::Type{Spec}) = false
copy_arg(spec::Spec) = spec # Already managed, no need to copy
# copy_arg(ro::ReadOnly{SpecArgs}) = Spec(ro, nothing) # Wrap in Spec



manage(spec::Spec) = spec # Already managed

function create_spec(f, args...; deduplicator=default_deduplicator(), kwargs...)
	p = deduplicate_leaves(deduplicator)∘copy_arg
	sa = create_spec_args(p, f, args, kwargs)
	sa = deduplicator(sa)
	Spec(sa, nothing)
end



Base.:(==)(a::Spec, b::Spec) = a.op == b.op && a.ro == b.ro


_get_spec_args(spec::Spec) = spec.ro.value

# get_hash(spec::Spec) = get_hash(spec.ro)






# TODO: Use predicate version for smart early-outs?
function visit_dependencies(f, v::Vector)
	visit_nested(v) do x
		x isa Spec && f(x)
	end
end
function visit_dependencies(f, sa::SpecArgs)
	visit_dependencies(f, sa.args)
	visit_dependencies(f, sa.kwargs)
end
visit_dependencies(f, spec::Spec) = visit_dependencies(f, _get_spec_args(spec))



deduplicate!(dedup::Deduplicator, spec::Spec) = Spec(deduplicate!(dedup, spec.ro), spec.use_cache, spec.forwarding_complete, spec.prefetch)




forward(spec::Spec) = Spec(spec.ro, forward(spec.op))



_prefetch(spec::ReadOnly{SpecArgs}) = Spec(spec, Prefetch())
_prefetch(spec::Spec) = _prefetch(spec.ro)
_prefetch(x) = x
prefetch(x::Any) = copy_nested(_prefetch, x)



# --- printing ---
function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, spec.f)
	else
		print_spec(io, spec; maxdepth=15)
	end
end
