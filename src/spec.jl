struct InternalSpec
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
	function InternalSpec(args, kwargs)
		@assert issorted(kwargs; by=first)
		new(args, kwargs)
	end
end

Base.:(==)(a::InternalSpec, b::InternalSpec) = a.args == b.args && a.kwargs == b.kwargs


function create_internal_spec(f, args, kwargs)
	a = Any[copy_nested(f,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[copy_nested(f,p) for p in kwargs]; by=first)
	InternalSpec(a,kw)
end


function _get_kwarg_index(ispec::InternalSpec, name::Symbol)
	r = searchsorted(ispec.kwargs, name=>nothing; by=first)
	isempty(r) && return nothing
	only(r)
end

function _get_kwarg(ispec::InternalSpec, name::Symbol, default=nothing)
	i = _get_kwarg_index(ispec,name)
	i !== nothing ? last(ispec.kwargs[i]) : default
end

get_versioned_function(ispec::InternalSpec, default=nothing) =
	_get_kwarg(ispec, :__versionedfunction, default)::Union{Nothing,VersionedFunction}



# Pair{Symbol,Any} currently hashes without any type information about the `Any`.
# And that would make structs with identical contents hash the same way, if they are the value of a kwarg.
# This is a workaround.
StableHashTraits.transformer(::Type{<:InternalSpec}) = StableHashTraits.Transformer(x->(x.args, first.(x.kwargs), last.(x.kwargs)))




struct Spec
	ro::ReadOnly{InternalSpec}
	use_cache::Bool
end


deduplicate_type(::Deduplicator, ::Type{Spec}) = false


preprocess_copy(x) = copy(x)


# TODO: We might want to avoid dynamic dispatch for pre-processing to speed it up. But that's for later.

# This are handled by copy_nested and are thus already new copies
preprocess_standard(a::Array) = a
preprocess_standard(d::Dict) = d
preprocess_standard(t::Tuple) = t
preprocess_standard(p::Pair) = p

# These are already managed, no need to copy
preprocess_standard(spec::Spec) = spec
preprocess_standard(ro::ReadOnly) = ro

preprocess_standard(x::AbstractString) = string(x) # Standardize strings
preprocess_standard(x::Symbol) = x # symbols are immutable, pass through
preprocess_standard(f::VersionedFunction) = f
preprocess_standard(f::Union{<:Base.Fix1,<:Base.Fix2}) = f

preprocess_standard(x) = preprocess_copy(x)







function create_spec(args...; deduplicator=default_deduplicator(), preprocess=deduplicator∘preprocess_standard, use_cache=true, kwargs...)
	ispec = create_internal_spec(preprocess, args, kwargs)

	# TODO: revise naming of everything here
	should_prefetch = false
	visit_dependencies(ispec) do x
		should_prefetch = should_prefetch || any(isequal(:__fetched=>true), _get_internal_spec(x).kwargs)
	end
	if should_prefetch
		push!(ispec.kwargs, :__preprocess_spec=>VersionedFunction(setup_prefetching_spec,v"0.0.1"))
		sort!(ispec.kwargs; by=first) # Must be sorted. But better if it was done elsewhere?
	end


	ispec = deduplicator(ispec)
	Spec(ispec, use_cache)
end


Base.:(==)(a::Spec, b::Spec) = a.use_cache == b.use_cache && a.ro == b.ro


_get_internal_spec(spec::Spec) = spec.ro.value

get_hash(spec::Spec) = get_hash(spec.ro)
get_versioned_function(spec::Spec) = get_versioned_function(_get_internal_spec(spec))




# TODO: Use predicate version for smart early-outs?
function visit_dependencies(f, v::Vector)
	visit_nested(v) do x
		x isa Spec && f(x)
	end
end


function visit_dependencies(f, ispec::InternalSpec)
	visit_dependencies(f, ispec.args)
	visit_dependencies(f, ispec.kwargs)
end
visit_dependencies(f, spec::Spec) = visit_dependencies(f, _get_internal_spec(spec))



deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro), spec.use_cache)



# --- printing ---
function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		print_spec(io, spec; maxdepth=10)
	end
end
