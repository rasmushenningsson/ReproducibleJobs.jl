struct PrintContext
	hashes::Set{String} # hashes seen at least once
	duplicates::Dict{String,Int} # hashes seen at least twice, mapping to an ordinal
end
PrintContext() = PrintContext(Set{String}(), Dict{String,Int}())

struct PrintReference
	str::String # What to print, usually the type of the referenced thing?
end

printreference(::T) where T = PrintReference(string(nameof(T)))
printreference(ispec::InternalSpec) = PrintReference(string(get_versioned_function(ispec).f))


Base.show(io::IO, ref::PrintReference) = print(io, ref.str)

struct PrintNode
	pc::PrintContext
	name::Symbol
	h::Union{Nothing,String}
	item::Any # ::T
	item_color::Symbol # for printstyled - TODO: other printstyled options
	children::Vector{PrintNode}
end
PrintNode(pc::PrintContext, name::Symbol, h, item; children=PrintNode[], item_color=:normal) =
	PrintNode(pc, name, h, item, item_color, children)



AbstractTrees.children(x::PrintNode) = x.children


_printitem(io::IO, item, item_color) =
	printstyled(IOContext(io, :limit=>true, :compact=>true, :short=>true), item; color=item_color) # Not great, but better than no IOContext

function _printitem(io::IO, item::Pair, item_color)
	_printitem(io, item.first, item_color)
	print(io, " => ")
	_printitem(io, item.second, item_color)
end
function _printitem(io::IO, item::Tuple, item_color)
	print(io, '(')
	for (i,x) in enumerate(item)
		first = i == 1
		last = i == length(item)
		first || print(io, ' ')
		_printitem(io, x, item_color)
		(first || !last) && print(io, ',')
	end
	print(io, ')')
end
function _printitem(io::IO, item::NamedTuple, item_color)
	print(io, '(')
	for (i,(k,v)) in enumerate(pairs(item))
		first = i == 1
		last = i == length(item)
		first || print(io, ' ')
		printstyled(io, k, " = "; color=item_color)
		_printitem(io, v, item_color)
		(first || !last) && print(io, ',')
	end
	print(io, ')')
end

_printitem(io::IO, item::T, item_color) where T<:Union{Base.Fix1,Base.Fix2} =
	_printitem(io, string(nameof(T), '(', item.f, ", ", repr(item.x), ')'), item_color)


function AbstractTrees.printnode(io::IO, x::PrintNode; kwargs...)
	x.name != Symbol("") && printstyled(io, x.name, ": "; color=:light_blue)
	_printitem(io, x.item, x.item_color)
	print(io, ' ')
	ord = get(x.pc.duplicates, x.h, nothing)
	if ord !== nothing
		printstyled(io, "#", ord; color=:blue)
	end
end



to_print_node!(pc::PrintContext, x::Any) = to_print_node!(pc, x, Symbol(""), nothing)


# Fallback
to_print_node!(pc::PrintContext, x::Any, name, h) = PrintNode(pc, name, h, x)



function to_print_node!(pc::PrintContext, x::AbstractArray{T}, name, h) where T
	if should_eltype_collapse(T)
		PrintNode(pc, name, h, x)
	else
		PrintNode(pc, name, h, nameof(typeof(x)); children=to_print_node!.(Ref(pc),x), item_color=:magenta)
	end
end

function to_print_node!(pc::PrintContext, d::AbstractDict{K,V}, name, h) where {K,V}
	if should_eltype_collapse(K)
		if should_eltype_collapse(V)
			PrintNode(pc, name, h, d)
		else
			children = [to_print_node!(pc,v,Symbol(string(k)),nothing) for (k,v) in d]
			PrintNode(pc, name, h, nameof(typeof(d)); children, item_color=:magenta)
		end
	else
		children = [to_print_node!(pc,k=>v) for (k,v) in d]
		PrintNode(pc, name, h, nameof(typeof(d)); children, item_color=:magenta)
	end
end

function to_print_node!(pc::PrintContext, x::T, name, h) where T<:Union{Pair,Tuple}
	if should_eltype_collapse(T)
		PrintNode(pc, name, h, x)
	else
		children = [to_print_node!(pc,y) for y in x]
		PrintNode(pc, name, h, nameof(typeof(x)); children, item_color=:magenta)
	end
end
function to_print_node!(pc::PrintContext, x::T, name, h) where T<:NamedTuple
	if should_eltype_collapse(T)
		PrintNode(pc, name, h, x)
	else
		children = [to_print_node!(pc,v,Symbol(string(k)),nothing) for (k,v) in pairs(x)]
		PrintNode(pc, name, h, nameof(typeof(x)); children, item_color=:magenta)
	end
end




# Unwrap Spec
to_print_node!(pc::PrintContext, spec::Spec, name, h) = to_print_node!(pc, spec.ro, name, h)

# Unwrap ReadOnly
function to_print_node!(pc::PrintContext, ro::ReadOnly, name, h)
	@assert h === nothing
	if ro.h in pc.hashes
		get!(pc.duplicates, ro.h, length(pc.duplicates)+1)
		PrintNode(pc, name, ro.h, printreference(ro.value); item_color=:blue) # TODO: color differently for Spec?
	else
		# first time we see the node
		push!(pc.hashes, ro.h)
		to_print_node!(pc, ro.value, name, ro.h)
	end
end


function to_print_node!(pc::PrintContext, ispec::InternalSpec, name, h)
	vf = get_versioned_function(ispec)

	c1 = to_print_node!.(Ref(pc), ispec.args)
	c2 = [to_print_node!(pc,v,k,nothing) for (k,v) in ispec.kwargs if k != :versionedfunction] # skip :versionedfunction since it is shown as the "item"
	children = vcat(c1,c2)

	PrintNode(pc, name, h, vf !== nothing ? vf.f : "Function not specified"; children, item_color=:green)
end



to_print_node(spec::Spec) = to_print_node!(PrintContext(), spec)


function print_spec_tree(io::IO, spec::Spec; kwargs...)
	tree = to_print_node(spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
