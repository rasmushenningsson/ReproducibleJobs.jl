struct Spec
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}
end

function Spec(args...; dedup=default_deduplicator(), kwargs...)
	a = Any[deduplicate!(dedup,x) for x in args]
	kw = sort!(Pair{Symbol,Any}[k=>deduplicate!(dedup,v) for (k,v) in kwargs]; by=first)
	Spec(a,kw)
end


function get_function(spec::Spec)
	r = searchsorted(spec.kwargs, :versionedfunction=>nothing; by=first)
	isempty(r) && return nothing
	i = only(r)
	return last(spec.kwargs[i])::VersionedFunction
end




# --- printing ---
struct SpecKWArg
	k::Symbol
	v::Any
end
SpecKWArg((k,v)::Pair{Symbol,<:Any}) = SpecKWArg(k,v)

# AbstractTrees.printnode(io::IO, kv::SpecKWArg; kwargs...) = print(io, kv.k)
# AbstractTrees.children(kv::SpecKWArg) = (kv.v,)
AbstractTrees.printnode(io::IO, kv::SpecKWArg; kwargs...) = print(io, kv.k, ": ", kv.v)


function AbstractTrees.printnode(io::IO, spec::Spec; kwargs...)
	# print(io, "Spec")
	f = get_function(spec)
	if f === nothing
		print(io, "Unknown function")
	else
		print(io, f)
	end
end
function AbstractTrees.children(spec::Spec)
	vcat(spec.args, SpecKWArg.(spec.kwargs))
end


function Base.show(io::IO, spec::Spec)
	# TODO: check, get(io,:compact,false)
	AbstractTrees.print_tree(io, spec)
end
