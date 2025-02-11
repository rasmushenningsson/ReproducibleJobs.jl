struct SpecArgs
	f::VersionedFunction
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
	function SpecArgs(f, args, kwargs)
		@assert issorted(kwargs; by=first)
		new(f, args, kwargs)
	end
end

Base.:(==)(a::SpecArgs, b::SpecArgs) = a.args == b.args && a.kwargs == b.kwargs

function create_spec_args(p, f, args, kwargs)
	a = Any[copy_nested(p,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[k=>copy_nested(p,v) for (k,v) in kwargs]; by=first)
	SpecArgs(f,a,kw)
end


function get_versioned_function(sa::SpecArgs, default=nothing)
	# # Probably refactor so we can customize KwargVector to return without wrapping in Managed
	# ret = get(KwargVector(sa.kwargs), :__versionedfunction, nothing)
	# ret === nothing ? default : unsafe_unmanage(ret)
	# @something get(sa.args, 1, nothing) Some(default)
	sa.f
end





struct Spec
	ro::ReadOnly{SpecArgs}
	use_cache::Bool
	forwarding_complete::Bool
	prefetch::Bool
end

Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting

function Base.getproperty(spec::Spec, s::Symbol)
	s === :f && return get_versioned_function(spec)
	s === :args && return get_args(spec)
	s === :kwargs && return get_kwargs(spec)
	getfield(spec, s)
end
function Base.propertynames(s::Spec, private::Bool=false)
	n = (:args, :kwargs)
	private ? (n..., fieldnames(Spec)...) : n
end


deduplicate_type(::Deduplicator, ::Type{Spec}) = false

_is_leaf_type(::Type{Spec}) = false
copy_arg(spec::Spec) = spec # Already managed, no need to copy

manage(spec::Spec) = spec # Already managed

function create_spec(f, args...; deduplicator=default_deduplicator(), use_cache=true, prefetch=false, kwargs...)
	p = deduplicate_leaves(deduplicator)∘copy_arg
	sa = create_spec_args(p, f, args, kwargs)
	sa = deduplicator(sa)
	Spec(sa, use_cache, false, prefetch)
end




Base.:(==)(a::Spec, b::Spec) = a.use_cache == b.use_cache && a.ro == b.ro


_get_spec_args(spec::Spec) = spec.ro.value

get_hash(spec::Spec) = get_hash(spec.ro)
_get_kwarg(spec::Spec, name::Symbol, args...) = _get_kwarg(_get_spec_args(spec), name, args...)
get_versioned_function(spec::Spec) = get_versioned_function(_get_spec_args(spec))



# TODO: access these through getpropery instead?
get_args(spec::Spec) = manage(_get_spec_args(spec).args)
get_kwargs(spec::Spec) = KwargVector(_get_spec_args(spec).kwargs)





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




_prefetch(spec::Spec) = Spec(spec.ro, spec.use_cache, spec.forwarding_complete, true)
_prefetch(x) = x
prefetch(x::Any) = copy_nested(_prefetch, x)



# --- printing ---
function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		print_spec(io, spec; maxdepth=10)
	end
end
