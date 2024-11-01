struct InternalSpec
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
end

Base.:(==)(a::InternalSpec, b::InternalSpec) = a.args == b.args && a.kwargs == b.kwargs


# function create_internal_spec(dedup::Deduplicator, args, kwargs)
# 	a = Any[deduplicate!(dedup,x) for x in args]
# 	kw = sort!(Pair{Symbol,Any}[k=>deduplicate!(dedup,v) for (k,v) in kwargs]; by=first)
# 	InternalSpec(a,kw)
# end

function create_internal_spec(f, args, kwargs)
	a = Any[copy_nested(f,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[copy_nested(f,p) for p in kwargs]; by=first)
	InternalSpec(a,kw)
end

# deduplicator_copy(dedup::Deduplicator, ispec::InternalSpec) =
# 	create_internal_spec(dedup, ispec.args, ispec.kwargs)

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


# TODO: We might want to avoid dynamic dispatch for pre-processing to speed it up. But that's for later.

# This are handled by copy_nested and are thus already new copies
preprocess_standard(a::Array) = a
preprocess_standard(d::Dict) = d
preprocess_standard(t::Tuple) = t
preprocess_standard(p::Pair) = p

# These are already managed, no need to copy
preprocess_standard(spec::Spec) = spec
preprocess_standard(ro::ReadOnly) = ro

# Fallback to make a copy, so deduplicator can store the value
preprocess_standard(x) = deepcopy(x) # or copy? but copy might not exist... Or a new function the user can override for their type more easily? Defaulting to copy/deepcopy?





# function create_spec(args..., ; deduplicator=default_deduplicator(), use_cache=true, kwargs...)
# 	ispec = create_internal_spec(deduplicator, args, kwargs)
# 	ispec = deduplicate!(deduplicator, ispec)
# 	Spec(ispec, use_cache)
# end


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



# --- WIP ---
# could_contain_spec(::Type{T}) where T =
# 	return Spec <: T || T <: Pair  || T <: Tuple || T <: AbstractArray || T <: AbstractDict

# _visit_dependencies(f, x) = nothing
# _visit_dependencies(f, spec::Spec) = f(spec)
# function _visit_dependencies(f, a::AbstractArray{T}) where T # TODO: make one-liner
# 	if could_contain_spec(eltype(a))
# 		for x in a
# 			_visit_dependencies(f, x)
# 		end
# 	end
# end
# function _visit_dependencies(f, p::Pair)
# 	_visit_dependencies(f, p.first)
# 	_visit_dependencies(f, p.second)
# end
# _visit_dependencies(f, t::Tuple) = _visit_dependencies.(f, t)
# function _visit_dependencies(f, d::AbstractDict{K,V}) where {K,V}
# 	if could_contain_spec(keytype(d))
# 		for k in keys(d)
# 			_visit_dependencies(f, k)
# 		end
# 	end
# 	if could_contain_spec(valuetype(d))
# 		for v in values(d)
# 			_visit_dependencies(f, v)
# 		end
# 	end
# end

# """
# 	visit_dependencies(f, spec::Spec)

# Call `f` for all `Spec`s contained in `spec`.
# `AbstractArray`s, `AbstractDict`s, `Tuple`s and `Pair`s will be visited recursively.
# The recursion stops when a `Spec` is reached, so only direct dependencies are visited.
# """
# function visit_dependencies(f, spec::Spec)
# 	ispec = _get_internal_spec(spec)
# 	_visit_dependencies(f, ispec.args)
# 	_visit_dependencies(f, ispec.kwargs)
# end
# -----------

# function visit_dependencies(f, spec::Spec)
# 	ispec = _get_internal_spec(spec)
# 	for x in ispec.args
# 		x isa Spec && f(x)
# 	end
# 	for (_,x) in ispec.kwargs
# 		x isa Spec && f(x)
# 	end
# end

deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro), spec.use_cache)



# --- printing ---


should_collapse(::Set{String}, x) = should_collapse(x)
function should_collapse(hashes::Set{String}, x::Union{Spec,ReadOnly})
	h = get_hash(x)
	if h in hashes
		true
	else
		push!(hashes, h)
		false
	end
end
should_collapse(::Any) = true


# TODO: find a better name?
function should_eltype_collapse(::Type{T}) where T
	T isa Union && return should_eltype_collapse(T.a) && should_eltype_collapse(T.b)
	T <: Spec && return false
	T <: ReadOnly && return false
	T <: AbstractArray && return false
	T <: AbstractDict && return false
	# T <: Pair && return false
	# T <: Tuple && return false
	# T <: NamedTuple && return false
	if (T <: Pair) || (T <: Tuple) || (T <: NamedTuple)
		return all(should_eltype_collapse, fieldtypes(T))
	end
	return true
end



should_collapse(::AbstractArray{T}) where T = should_eltype_collapse(T)
should_collapse(::AbstractDict{T1,T2}) where {T1,T2} = should_eltype_collapse(T1) && should_eltype_collapse(T2)
should_collapse(::T) where T<:Union{<:Tuple,<:NamedTuple,<:Pair} = all(should_eltype_collapse, fieldtypes(T))


function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		print_spec(io, spec; maxdepth=10)
	end
end
