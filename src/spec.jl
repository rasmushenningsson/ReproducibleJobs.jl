struct InternalSpec
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
end

function _internal_spec(dedup::Deduplicator, args, kwargs)
	a = Any[deduplicate!(dedup,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[k=>deduplicate!(dedup,v) for (k,v) in kwargs]; by=first)
	InternalSpec(a,kw)
end

InternalSpec(dedup::Deduplicator, args...; kwargs...) = _internal_spec(dedup, args, kwargs)
deduplicator_copy(dedup::Deduplicator, ispec::InternalSpec) =
	_internal_spec(dedup, ispec.args, ispec.kwargs)

function get_function(ispec::InternalSpec)
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


_get_internal(spec::Spec) = spec.ro.value
get_function(spec::Spec) = get_function(_get_internal(spec))

deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro))



# --- printing ---
struct DAGPrintContext{T}
	x::T # current value
	hashes::Vector{String} # which hashes we have seen, used to collapse all but the first Spec with a given hash
end

struct SpecKWArg
	k::Symbol
	v::Any
end

AbstractTrees.printnode(io::IO, kv::SpecKWArg; kwargs...) = print(io, kv.k, ": ", kv.v)


# Default to printing without DAGPrintContext
AbstractTrees.printnode(io::IO, (;x,hashes)::DAGPrintContext; kwargs...) = AbstractTrees.printnode(io, x; kwargs...)

# Make pair printing nicer, and use printnode for first and second
function AbstractTrees.printnode(io::IO, (;x,hashes)::DAGPrintContext{<:Pair}; kwargs...)
	AbstractTrees.printnode(io, DAGPrintContext(x.first, hashes))
	print(io, " => ")
	AbstractTrees.printnode(io, DAGPrintContext(x.second, hashes))
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
function AbstractTrees.printnode(io::IO, spec::Spec; kwargs...)
	f = get_function(spec)
	if f === nothing
		print(io, "Function not specified")
	else
		print(io, f)
	end
	printstyled(io, ' ', spec.ro.h[1:min(6,end)]; color=:red)
end

AbstractTrees.children((;x,hashes)::DAGPrintContext{<:Pair}) = AbstractTrees.children(DAGPrintContext(x.second, hashes))
function AbstractTrees.children((;x,hashes)::DAGPrintContext{Spec})
	x.ro.h in hashes && return ()

	push!(hashes, x.ro.h) # is this the right place?
	ispec = _get_internal(x)
	c = vcat(ispec.args, [SpecKWArg(k,v) for (k,v) in ispec.kwargs if k != :versionedfunction]) # skip :versionedfunction since it is shown at top
	DAGPrintContext.(c, Ref(hashes))
end
AbstractTrees.children(ctx::DAGPrintContext) = DAGPrintContext.(AbstractTrees.children(ctx.x), Ref(ctx.hashes))

function Base.show(io::IO, spec::Spec)
	# TODO: check, get(io,:compact,false)
	AbstractTrees.print_tree(io, DAGPrintContext(spec,String[]))
end
