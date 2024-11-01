struct InternalSpec
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
end

Base.:(==)(a::InternalSpec, b::InternalSpec) = a.args == b.args && a.kwargs == b.kwargs


function create_internal_spec(f, args, kwargs)
	a = Any[copy_nested(f,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[copy_nested(f,p) for p in kwargs]; by=first)
	InternalSpec(a,kw)
end

function get_versioned_function(ispec::InternalSpec)
	r = searchsorted(ispec.kwargs, :versionedfunction=>nothing; by=first)
	isempty(r) && return nothing
	i = only(r)
	return last(ispec.kwargs[i])::VersionedFunction
end


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

# Fallback to make a copy, so deduplicator can store the value
# preprocess_standard(x) = deepcopy(x) # or copy? but copy might not exist... Or a new function the user can override for their type more easily? Defaulting to copy/deepcopy?

preprocess_standard(x) = preprocess_copy(x)







function create_spec(args...; deduplicator=default_deduplicator(), preprocess=deduplicator∘preprocess_standard, use_cache=true, kwargs...)
	ispec = create_internal_spec(preprocess, args, kwargs)
	ispec = deduplicator(ispec)
	Spec(ispec, use_cache)
end


Base.:(==)(a::Spec, b::Spec) = a.use_cache == b.use_cache && a.ro == b.ro


_get_internal_spec(spec::Spec) = spec.ro.value

get_hash(spec::Spec) = get_hash(spec.ro)
get_versioned_function(spec::Spec) = get_versioned_function(_get_internal_spec(spec))





function visit_dependencies(f, spec::Spec)
	ispec = _get_internal_spec(spec)

	# TODO: Use predicate version for smart early-outs?
	visit_nested(ispec.args) do x
		x isa Spec && f(x)
	end
	visit_nested(ispec.kwargs) do x
		x isa Spec && f(x)
	end
end



deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro), spec.use_cache)



# --- printing ---
function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		print_spec(io, spec; maxdepth=10)
	end
end
