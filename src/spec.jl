struct InternalSpec
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
end

Base.:(==)(a::InternalSpec, b::InternalSpec) = a.args == b.args && a.kwargs == b.kwargs


function _internal_spec(dedup::Deduplicator, args, kwargs)
	a = Any[deduplicate!(dedup,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[k=>deduplicate!(dedup,v) for (k,v) in kwargs]; by=first)
	InternalSpec(a,kw)
end

InternalSpec(dedup::Deduplicator, args...; kwargs...) = _internal_spec(dedup, args, kwargs)
deduplicator_copy(dedup::Deduplicator, ispec::InternalSpec) =
	_internal_spec(dedup, ispec.args, ispec.kwargs)

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
end
create_spec(args...; deduplicator=default_deduplicator(), kwargs...) =
	Spec(deduplicate!(deduplicator, InternalSpec(deduplicator, args...; kwargs...)))


Base.:(==)(a::Spec, b::Spec) = a.ro == b.ro


_get_internal_spec(spec::Spec) = spec.ro.value

get_hash(spec::Spec) = get_hash(spec.ro)
get_versioned_function(spec::Spec) = get_versioned_function(_get_internal_spec(spec))
function visit_dependencies(f, spec::Spec)
	ispec = _get_internal_spec(spec)
	for x in ispec.args
		x isa Spec && f(x)
	end
	for (_,x) in ispec.kwargs
		x isa Spec && f(x)
	end
end

deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro))



# --- printing ---
struct DAGPrintContext{T}
	x::T # current value
	hashes::Set{String} # which hashes we have seen, used to collapse all but the first Spec with a given hash
	collapsed::Bool
end

dag_print_context(ctx::DAGPrintContext, x) = DAGPrintContext(x, ctx.hashes, false)
function dag_print_context(ctx::DAGPrintContext, x::Union{Spec,ReadOnly})
	h = get_hash(x)
	if h in ctx.hashes
		DAGPrintContext(x, ctx.hashes, true)
	else
		push!(ctx.hashes, h)
		DAGPrintContext(x, ctx.hashes, false)
	end
end

struct SpecKWArg
	k::Symbol
	v::Any
end

function AbstractTrees.printnode(io::IO, ctx::DAGPrintContext{SpecKWArg}; kwargs...)
	printstyled(io, ctx.x.k, ": "; color=:light_blue)
	AbstractTrees.printnode(io, ctx.x.v)
end

# Default to printing without DAGPrintContext
AbstractTrees.printnode(io::IO, ctx::DAGPrintContext; kwargs...) = AbstractTrees.printnode(io, ctx.x; kwargs...)

# Make pair printing nicer, and use printnode for first and second
function AbstractTrees.printnode(io::IO, ctx::DAGPrintContext{<:Pair}; kwargs...)
	AbstractTrees.printnode(io, ctx.x.first)
	print(io, " => ")
	AbstractTrees.printnode(io, dag_print_context(ctx, ctx.x.second))
end

function AbstractTrees.printnode(io::IO, ctx::DAGPrintContext{T}; kwargs...) where {T<:Union{Base.Fix1,Base.Fix2}}
	f = ctx.x
	print(io, nameof(T), '(')
	show(io, f.f)
	print(io, ", ")
	show(io, f.x)
	print(io, ')')
end

# Spec printing should show function name
function AbstractTrees.printnode(io::IO, ctx::DAGPrintContext{Spec}; kwargs...)
	spec = ctx.x
	f = get_versioned_function(spec)
	printstyled(io, f !== nothing ? f.f : "Function not specified"; bold=true, color=:green)
	printstyled(io, ' ', spec.ro.h[1:min(6,end)]; color=:red)
	ctx.collapsed && printstyled(io, " collapsed"; color=:light_black)
end

AbstractTrees.children(ctx::DAGPrintContext{<:Pair}) = AbstractTrees.children(dag_print_context(ctx, ctx.x.second))
function AbstractTrees.children(ctx::DAGPrintContext{Spec})
	ctx.collapsed && return ()
	ispec = _get_internal_spec(ctx.x)
	c = vcat(ispec.args, [SpecKWArg(k,v) for (k,v) in ispec.kwargs if k != :versionedfunction]) # skip :versionedfunction since it is shown at top
	dag_print_context.(Ref(ctx), c)
end
function AbstractTrees.children(ctx::DAGPrintContext{<:ReadOnly})
	ctx.collapsed && return ()
	[dag_print_context(ctx,p) for p in AbstractTrees.children(ctx.x.value)]
end
AbstractTrees.children(ctx::DAGPrintContext) = dag_print_context.(Ref(ctx), AbstractTrees.children(ctx.x))

function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, get_versioned_function(spec))
	else
		AbstractTrees.print_tree(io, DAGPrintContext(spec, Set{String}(), false))
	end
end
