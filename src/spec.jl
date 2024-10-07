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
Spec(args...; dedup=default_deduplicator(), kwargs...) =
	Spec(deduplicate!(dedup, InternalSpec(dedup, args...; kwargs...)))

_get_internal(spec::Spec) = spec.ro.value
get_function(spec::Spec) = get_function(_get_internal(spec))

deduplicate!(dedup::Deduplicator, spec::Spec) =	Spec(deduplicate!(dedup, spec.ro))



# --- printing ---
struct SpecKWArg
	k::Symbol
	v::Any
end

AbstractTrees.printnode(io::IO, kv::SpecKWArg; kwargs...) = print(io, kv.k, ": ", kv.v)

function AbstractTrees.printnode(io::IO, spec::Spec; kwargs...)
	# print(io, "Spec")
	f = get_function(spec)
	if f === nothing
		print(io, "Function not specified")
	else
		print(io, f)
	end
	printstyled(io, ' ', spec.ro.h[1:min(6,end)]; color=:red)
end
function AbstractTrees.children(spec::Spec)
	ispec = _get_internal(spec)
	vcat(ispec.args, [SpecKWArg(k,v) for (k,v) in ispec.kwargs if k != :versionedfunction]) # skip :versionedfunction since it is shown at top
end

function Base.show(io::IO, spec::Spec)
	# TODO: check, get(io,:compact,false)
	AbstractTrees.print_tree(io, spec)
end
