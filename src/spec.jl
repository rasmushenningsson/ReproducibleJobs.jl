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



struct Spec
	ro::ReadOnly{InternalSpec}
end
create_spec(args...; dedup=default_deduplicator(), kwargs...) =
	Spec(deduplicate!(dedup, InternalSpec(dedup, args...; kwargs...)))


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


AbstractTrees.printnode(io::IO, (;x,hashes)::DAGPrintContext; kwargs...) = AbstractTrees.printnode(io,x; kwargs...)
function AbstractTrees.printnode(io::IO, (;x,hashes)::DAGPrintContext{<:Pair}; kwargs...)
	# Avoid showing value twice
	show(io, first(x))
	print(io, " => ")
end
function AbstractTrees.printnode(io::IO, spec::Spec; kwargs...)
	f = get_function(spec)
	if f === nothing
		print(io, "Function not specified")
	else
		print(io, f)
	end
	printstyled(io, ' ', spec.ro.h[1:min(6,end)]; color=:red)
end

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
