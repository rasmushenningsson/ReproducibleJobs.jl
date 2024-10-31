struct PrintContext
	hashes::Set{String} # hashes seen at least once
	# duplicates::Set{String} # hashes seen at least twice
	duplicates::Dict{String,Int} # hashes seen at least twice, mapping to an ordinal
end
# PrintContext() = PrintContext(Set{String}(), Set{String}())
PrintContext() = PrintContext(Set{String}(), Dict{String,Int}())

# struct PrintReference end
struct PrintReference
	str::String # What to print, usually the type of the referenced thing?
end
PrintReference(::Type{T}) where T = PrintReference(string(nameof(T)))
PrintReference(::Type{InternalSpec}) = PrintReference("Spec")

Base.show(io::IO, ref::PrintReference) = print(io, ref.str)

struct PrintItem#{T}
	pc::PrintContext
	name::Symbol
	h::Union{Nothing,String}
	item::Any # ::T
	item_color::Symbol # for printstyled - TODO: other printstyled options
	children::Vector{PrintItem}
end
PrintItem(pc::PrintContext, name::Symbol, h, item; children=PrintItem[], item_color=:normal) =
	PrintItem(pc, name, h, item, item_color, children)



AbstractTrees.children(x::PrintItem) = x.children


function AbstractTrees.printnode(io::IO, x::PrintItem; kwargs...)
	x.name != Symbol("") && printstyled(io, x.name, ": "; color=:light_blue)
	# x.item === PrintReference() || printstyled(io, x.item, ' '; color=x.item_color) # TODO: ensure this is printed compactly (i.e. no line breaks) somehow
	printstyled(io, x.item, ' '; color=x.item_color) # TODO: ensure this is printed compactly (i.e. no line breaks) somehow
	# x.h in x.pc.duplicates && printstyled(io, x.h[1:min(end,6)]; color=:red)
	ord = get(x.pc.duplicates, x.h, nothing)
	if ord !== nothing
		printstyled(io, "#", ord; color=:red)
	end
end



to_print_item!(pc::PrintContext, x::Any) = to_print_item!(pc, x, Symbol(""), nothing)


# Fallback
to_print_item!(pc::PrintContext, x::Any, name, h) = PrintItem(pc, name, h, x)


function to_print_item!(pc::PrintContext, x::AbstractArray{T}, name, h) where T
	if should_eltype_collapse(T)
		PrintItem(pc, name, h, x)
	else
		PrintItem(pc, name, h, nameof(typeof(x)); children=to_print_item!.(Ref(pc),x), item_color=:magenta)
	end
end

function to_print_item!(pc::PrintContext, d::AbstractDict{K,V}, name, h) where {K,V}
	if should_eltype_collapse(K)
		if should_eltype_collapse(V)
			PrintItem(pc, name, h, d)
		else
			children = [to_print_item!(pc,v,Symbol(string(k)),nothing) for (k,v) in d]
			PrintItem(pc, name, h, nameof(typeof(d)); children, item_color=:magenta)
		end
	else
		children = [to_print_item!(pc,k=>v) for (k,v) in d]
		PrintItem(pc, name, h, nameof(typeof(d)); children, item_color=:magenta)
	end
end

# function to_print_item!(pc::PrintContext, p::Pair{K,V}, name, h) where {K,V}
# 	if should_eltype_collapse(K) && should_eltype_collapse(V)
# 		PrintItem(pc, name, h, p)
# 	else
# 		children = [to_print_item!(pc,p.first), to_print_item!(pc,p.second)]
# 		PrintItem(pc, name, h, nameof(typeof(p)); children, item_color=:magenta)
# 	end
# end

function to_print_item!(pc::PrintContext, x::T, name, h) where T<:Union{Pair,Tuple}
	if should_eltype_collapse(T)
		PrintItem(pc, name, h, x)
	else
		children = [to_print_item!(pc,y) for y in x]
		PrintItem(pc, name, h, nameof(typeof(x)); children, item_color=:magenta)
	end
end
function to_print_item!(pc::PrintContext, x::T, name, h) where T<:NamedTuple
	if should_eltype_collapse(T)
		PrintItem(pc, name, h, x)
	else
		children = [to_print_item!(pc,v,Symbol(string(k)),nothing) for (k,v) in pairs(x)]
		PrintItem(pc, name, h, nameof(typeof(x)); children, item_color=:magenta)
	end
end




# Unwrap Spec
to_print_item!(pc::PrintContext, spec::Spec, name, h) = to_print_item!(pc, spec.ro, name, h)

# Unwrap ReadOnly
function to_print_item!(pc::PrintContext, ro::ReadOnly{T}, name, h) where T
	@assert h === nothing
	if ro.h in pc.hashes
		# push!(pc.duplicates, ro.h)
		get!(pc.duplicates, ro.h, length(pc.duplicates)+1)
		# PrintItem(pc, name, ro.h, PrintReference())
		PrintItem(pc, name, ro.h, PrintReference(T); item_color=:light_black)
	else
		# first time we see the item
		push!(pc.hashes, ro.h)
		to_print_item!(pc, ro.value, name, ro.h)
	end
end


function to_print_item!(pc::PrintContext, ispec::InternalSpec, name, h)
	vf = get_versioned_function(ispec)

	# c1 = dag_print_context.(Ref(ctx), ispec.args)
	# c2 = [dag_print_context(ctx,v; name=k) for (k,v) in ispec.kwargs if k != :versionedfunction] # skip :versionedfunction since it is shown at top

	# children = PrintItem[]

	c1 = to_print_item!.(Ref(pc), ispec.args)
	c2 = [to_print_item!(pc,v,k,nothing) for (k,v) in ispec.kwargs if k != :versionedfunction] # skip :versionedfunction since it is shown as the "item"
	children = vcat(c1,c2)

	PrintItem(pc, name, h, vf !== nothing ? vf.f : "Function not specified"; children, item_color=:green)
end



to_print_item(spec::Spec) = to_print_item!(PrintContext(), spec)


function print_spec_tree(io::IO, spec::Spec; kwargs...)
	tree = to_print_item(spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
