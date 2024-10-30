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
struct DAGPrintContext{T}
	name::Symbol # optional name of parameter
	x::T # current value
	hashes::Set{String} # which hashes we have seen, used to collapse all but the first Spec with a given hash
	collapsed::Bool
end


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


# TODO: find a better name
function subtype_collapse(::Type{T}) where T
	Spec <: T && return false
	ReadOnly <: T && return false # Hmm. This doesn't work, right? Because ReadOnly is not concrete.
	AbstractArray <: T && return false
	AbstractDict <: T && return false
	Tuple <: T && return false
	NamedTuple <: T && return false
	return true
end

should_collapse(::AbstractArray{T}) where T = subtype_collapse(T)
should_collapse(::AbstractDict{T1,T2}) where {T1,T2} = subtype_collapse(T1) && subtype_collapse(T2)
should_collapse(::T) where T<:Union{<:Tuple,<:NamedTuple,<:Pair} = all(subtype_collapse, fieldtypes(T))

dag_print_context(ctx::DAGPrintContext, x; name=Symbol("")) = DAGPrintContext(name, x, ctx.hashes, should_collapse(ctx.hashes, x))



# This prints the optional name and forwards to specific printing for different types
function AbstractTrees.printnode(io::IO, ctx::DAGPrintContext; kwargs...)
	ctx.name !== Symbol("") && printstyled(io, ctx.name, ": "; color=:light_blue)
	_printnode(io, ctx; kwargs...)
end

# TODO: merge with the above?
function AbstractTrees.printnode(io::IO, ctx::DAGPrintContext{T}; kwargs...) where T<:Union{<:AbstractArray, <:AbstractDict, <:Tuple, <:NamedTuple, <:Pair}
	ctx.name !== Symbol("") && printstyled(io, ctx.name, ": "; color=:light_blue)
	if ctx.collapsed
		_printnode(io, ctx; kwargs...)
	else
		# printstyled(io, "::", T; color=:magenta)
		# printstyled(io, "::", nameof(T); color=:magenta)
		printstyled(io, nameof(T); color=:magenta)
	end
end



# Default to printing without DAGPrintContext
_printnode(io::IO, ctx::DAGPrintContext; kwargs...) = AbstractTrees.printnode(io, ctx.x; kwargs...)


function _printnode(io::IO, ctx::DAGPrintContext{<:Pair}; kwargs...)
	AbstractTrees.printnode(io, dag_print_context(ctx, ctx.x.first))
	print(io, " => ")
	AbstractTrees.printnode(io, dag_print_context(ctx, ctx.x.second))
end


function _printnode(io::IO, ctx::DAGPrintContext{T}; kwargs...) where {T<:Union{Base.Fix1,Base.Fix2}}
	f = ctx.x
	print(io, nameof(T), '(')
	show(io, f.f)
	print(io, ", ")
	show(io, f.x)
	print(io, ')')
end

# Spec printing should show function name
function _printnode(io::IO, ctx::DAGPrintContext{Spec}; kwargs...)
	spec = ctx.x
	f = get_versioned_function(spec)
	printstyled(io, f !== nothing ? f.f : "Function not specified"; bold=true, color=:green)
	printstyled(io, ' ', spec.ro.h[1:min(6,end)]; color=:red)
	ctx.collapsed && printstyled(io, " collapsed"; color=:light_black)
end

function _printnode(io::IO, ctx::DAGPrintContext{<:ReadOnly}; kwargs...)
	AbstractTrees.printnode(io, dag_print_context(ctx, ctx.x.value); kwargs...)
	printstyled(io, ' ', ctx.x.h[1:min(6,end)]; color=:red)
end



function _children(ctx::DAGPrintContext{Spec})
	ctx.collapsed && return ()
	ispec = _get_internal_spec(ctx.x)
	c1 = dag_print_context.(Ref(ctx), ispec.args)
	c2 = [dag_print_context(ctx,v; name=k) for (k,v) in ispec.kwargs if k != :versionedfunction] # skip :versionedfunction since it is shown at top
	vcat(c1,c2)
end
function _children(ctx::DAGPrintContext{<:ReadOnly})
	ctx.collapsed && return ()
	AbstractTrees.children(dag_print_context(ctx, ctx.x.value))
end


_children(ctx::DAGPrintContext{<:Pair}) = (dag_print_context(ctx, ctx.x.first), dag_print_context(ctx, ctx.x.second))


_children(ctx::DAGPrintContext{<:Union{<:AbstractArray, <:Tuple}}) =
	dag_print_context.(Ref(ctx), ctx.x)
_children(ctx::DAGPrintContext{<:AbstractDict}) =
	[dag_print_context(ctx,k=>v) for (k,v) in pairs(ctx.x)]
_children(ctx::DAGPrintContext{<:AbstractDict{<:Union{Symbol,String}}}) =
	[dag_print_context(ctx,v; name=Symbol(k)) for (k,v) in pairs(ctx.x)]
_children(ctx::DAGPrintContext{<:NamedTuple}) =
	[dag_print_context(ctx,v; name=k) for (k,v) in pairs(ctx.x)]


# # This uses AbstractTrees default definitions for what has children
# _children(ctx::DAGPrintContext) = dag_print_context.(Ref(ctx), AbstractTrees.children(ctx.x))

# Only types selected explicitly have children
_children(ctx::DAGPrintContext) = ()


function AbstractTrees.children(ctx::DAGPrintContext)
	ctx.collapsed && return ()
	_children(ctx)
end





function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		AbstractTrees.print_tree(io, DAGPrintContext(Symbol(""), spec, Set{String}(), false))
	end
end
