struct SpecArgs
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
	function SpecArgs(args, kwargs)
		@assert issorted(kwargs; by=first)
		new(args, kwargs)
	end
end

Base.:(==)(a::SpecArgs, b::SpecArgs) = a.args == b.args && a.kwargs == b.kwargs


function create_spec_args(f, args, kwargs)
	a = Any[copy_nested(f,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[k=>copy_nested(f,v) for (k,v) in kwargs]; by=first)
	SpecArgs(a,kw)
end


function _get_kwarg_index(sa::SpecArgs, name::Symbol)
	r = searchsorted(sa.kwargs, name=>nothing; by=first)
	isempty(r) && return nothing
	only(r)
end

function _get_kwarg(sa::SpecArgs, name::Symbol, default=nothing)
	i = _get_kwarg_index(sa,name)
	i !== nothing ? last(sa.kwargs[i]) : default
end

get_versioned_function(sa::SpecArgs, default=nothing) =
	_get_kwarg(sa, :__versionedfunction, default)::Union{Nothing,VersionedFunction}



# Pair{Symbol,Any} currently hashes without any type information about the `Any`.
# And that would make structs with identical contents hash the same way, if they are the value of a kwarg.
# This is a workaround.
StableHashTraits.transformer(::Type{<:SpecArgs}) = StableHashTraits.Transformer(x->(x.args, first.(x.kwargs), last.(x.kwargs)))




struct Spec
	ro::ReadOnly{SpecArgs}
	use_cache::Bool
	fully_forwarded::Bool
end
Spec(ro::ReadOnly{SpecArgs}, use_cache::Bool) = Spec(ro, use_cache, false)


deduplicate_type(::Deduplicator, ::Type{Spec}) = false


_is_leaf_type(::Type{Spec}) = false
preprocess(spec::Spec) = spec # Already managed, no need to copy





function create_spec(args...; deduplicator=default_deduplicator(), use_cache=true, kwargs...)
	sa = create_spec_args(preprocessor(deduplicator), args, kwargs)
	sa = deduplicator(sa)
	Spec(sa, use_cache)
end




Base.:(==)(a::Spec, b::Spec) = a.use_cache == b.use_cache && a.ro == b.ro


_get_spec_args(spec::Spec) = spec.ro.value

get_hash(spec::Spec) = get_hash(spec.ro)
_get_kwarg(spec::Spec, name::Symbol, args...) = _get_kwarg(_get_spec_args(spec), name, args...)
get_versioned_function(spec::Spec) = get_versioned_function(_get_spec_args(spec))




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



deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro), spec.use_cache)



# --- printing ---
function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		print_spec(io, spec; maxdepth=10)
	end
end
