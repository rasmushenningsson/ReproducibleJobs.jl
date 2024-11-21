_nameof(::Type{T}) where T = Symbol(first(eachsplit(repr(T),'{')))
_nameof(::Type{<:NamedTuple}) = Symbol("NamedTuple") # is there a better way to avoid @NamedTuple?
_nameof(::Type{<:ReadOnlyArray{V,N,T}}) where {V,N,T} = _nameof(T)

_typenameof(x::T) where T = _nameof(T)

struct PrintContext
	hashes::Set{String} # hashes seen at least once
	duplicates::Dict{String,Int} # hashes seen at least twice, mapping to an ordinal
	depth::Int
end
PrintContext() = PrintContext(Set{String}(), Dict{String,Int}(), 0)

descend(pc::PrintContext) = PrintContext(pc.hashes, pc.duplicates, pc.depth+1)


struct PrintReference
	str::String # What to print, usually the type of the referenced thing?
end

printreference(::T) where T = PrintReference(_nameof(T))
printreference(sa::SpecArgs; prefetch) =
	PrintReference(string(get_versioned_function(sa).f, prefetch ? " (prefetched)" : ""))

Base.show(io::IO, ref::PrintReference) = print(io, ref.str)


struct PrintFetched
	f::Any
end
function Base.show(io::IO, x::PrintFetched)
	show(io, x.f)
	print(io, " (prefetched)")
end


"""
	ItemWrapper{T}

Items wrapped in a an ItemWrapper object are printed using `show` by default, and printing can be customized.
"""
struct ItemWrapper{T}
	item::T
end

wrap_item(x) = x

wrap_item(x::Union{<:Base.Fix1,<:Base.Fix2}) = ItemWrapper(x)
wrap_item(x::AbstractString) = ItemWrapper(x)

wrap_item(x::Union{<:AbstractArray,<:Tuple}) = wrap_item.(x)
wrap_item(p::Pair) = wrap_item(p.first) => wrap_item(p.second)
wrap_item(d::AbstractDict) = Dict((wrap_item(k)=>wrap_item(v) for (k,v) in pairs(d)))
wrap_item(s::AbstractSet) = Set((wrap_item(x) for x in s))
wrap_item(nt::NamedTuple) = map(wrap_item, nt)

Base.show(io::IO, w::ItemWrapper) = show(io, w.item)
function Base.show(io::IO, w::ItemWrapper{T}) where T<:Union{<:Base.Fix1,<:Base.Fix2}
	print(io, string(_nameof(T), '(', w.item.f, ", ", repr(w.item.x), ')'))
end




struct PrintNode
	pc::PrintContext
	name::Symbol
	h::Union{Nothing,String}
	item::Any # ::T
	item_color::Symbol # for printstyled - TODO: other printstyled options
	children::Vector{PrintNode}
end

create_print_node(pc::PrintContext, name::Symbol, h, item; children=PrintNode[], item_color=:normal) =
	PrintNode(pc, name, h, wrap_item(item), item_color, children)


AbstractTrees.children(x::PrintNode) = x.children



_printitem(io::IO, item, item_color) =
	printstyled(IOContext(io, :limit=>true, :compact=>true, :short=>true), item; color=item_color) # Not great, but better than no IOContext


function get_max_print(io, min_len=20)
	n_chars_printed = get(io, :n_chars_printed, 0)
	width = get(io, :displaysize, (0,0))[2]
	max_print = max(min_len, width-n_chars_printed)
end

function _print_limited_string(io::IO, str::AbstractString, suffix, item_color) # TODO: Better name
	max_print = get_max_print(io)

	if length(str) <= max_print
		printstyled(io, str; color=item_color)
	else
		printstyled(io, @view(str[1:max_print-length(suffix)]), suffix; color=item_color)
	end
end

function _printitem(io::IO, a::AbstractArray, item_color)
	# This is a bit of a hack.
	# Print to a string and skip the initial type info.
	# But otherwise we need to rewrite the entire Array printing, or rely on internals.
	str = repr(a)
	i = findfirst('[', str)
	i !== nothing && (str = @view str[i:end])
	_print_limited_string(io, str, "...]", item_color)
end

function _printitem(io::IO, a::AbstractDict, item_color)
	# This is a bit of a hack.
	# Print to a string and skip the initial type info.
	# But otherwise we need to rewrite the entire Dict printing, or rely on internals.
	str = repr(a)
	str = replace(str, r"^Dict\{.+\}\("=>"Dict("; count=1) # There might be some weird edge case where this doesn't work
	_print_limited_string(io, str, "...)", item_color)
end



function AbstractTrees.printnode(io::IO, x::PrintNode; kwargs...)
	indent = x.pc.depth*3
	if x.name != Symbol("")
		printstyled(io, x.name, ": "; color=:light_blue)
		indent += length(string(x.name))+2
	end

	ord = get(x.pc.duplicates, x.h, nothing)
	suffix = ord !== nothing ? " #$ord" : ""
	io = IOContext(io, :n_chars_printed=>indent+length(suffix))
	_printitem(io, x.item, x.item_color)
	isempty(suffix) || printstyled(io, suffix; color=:blue)
end



to_print_node!(pc::PrintContext, x::Any) = to_print_node!(pc, x, Symbol(""), nothing)


# Fallback
to_print_node!(pc::PrintContext, x::Any, name, h) = create_print_node(pc, name, h, x)



function _should_collapse(::Type{T}) where T
	T isa Union && return _should_collapse(T.a) && _should_collapse(T.b)
	T <: Spec && return false
	T <: ReadOnly && return false
	T <: AbstractArray && return false
	T <: AbstractDict && return false
	T <: AbstractSet && return false
	if (T <: Pair) || (T <: Tuple) || (T <: NamedTuple)
		return all(_should_collapse, fieldtypes(T))
	end
	return true
end


function to_print_node!(pc::PrintContext, x::AbstractArray{T}, name, h) where T
	if _should_collapse(T)
		create_print_node(pc, name, h, x)
	else
		create_print_node(pc, name, h, _typenameof(x); children=to_print_node!.(Ref(descend(pc)),x), item_color=:magenta)
	end
end

function to_print_node!(pc::PrintContext, d::AbstractDict{K,V}, name, h) where {K,V}
	if _should_collapse(K)
		if _should_collapse(V)
			create_print_node(pc, name, h, d)
		else
			children = [to_print_node!(descend(pc),v,Symbol(string(k)),nothing) for (k,v) in d]
			create_print_node(pc, name, h, _typenameof(d); children, item_color=:magenta)
		end
	else
		children = [to_print_node!(descend(pc),k=>v) for (k,v) in d]
		create_print_node(pc, name, h, _typenameof(d); children, item_color=:magenta)
	end
end
function to_print_node!(pc::PrintContext, s::AbstractSet{T}, name, h) where T
	if _should_collapse(T)
		create_print_node(pc, name, h, s)
	else
		children = [to_print_node!(descend(pc),x) for x in s]
		create_print_node(pc, name, h, _typenameof(s); children, item_color=:magenta)
	end
end

function to_print_node!(pc::PrintContext, x::T, name, h) where T<:Union{Pair,Tuple}
	if _should_collapse(T)
		create_print_node(pc, name, h, x)
	else
		children = [to_print_node!(descend(pc),y) for y in x]
		create_print_node(pc, name, h, _typenameof(x); children, item_color=:magenta)
	end
end
function to_print_node!(pc::PrintContext, x::T, name, h) where T<:NamedTuple
	if _should_collapse(T)
		create_print_node(pc, name, h, x)
	else
		children = [to_print_node!(descend(pc),v,Symbol(string(k)),nothing) for (k,v) in pairs(x)]
		create_print_node(pc, name, h, _typenameof(x); children, item_color=:magenta)
	end
end




# Unwrap Spec
to_print_node!(pc::PrintContext, spec::Spec, name, h) = to_print_node!(pc, spec.ro, name, h; spec.prefetch)

# Unwrap ReadOnly
function to_print_node!(pc::PrintContext, ro::ReadOnly, name, h; kwargs...)
	@assert h === nothing
	if ro.h in pc.hashes
		get!(pc.duplicates, ro.h, length(pc.duplicates)+1)
		create_print_node(pc, name, ro.h, printreference(ro.value; kwargs...); item_color=:blue) # TODO: color differently for Spec?
	else
		# first time we see the node
		push!(pc.hashes, ro.h)
		to_print_node!(pc, ro.value, name, ro.h; kwargs...)
	end
end


function to_print_node!(pc::PrintContext, sa::SpecArgs, name, h; prefetch)
	c1 = to_print_node!.(Ref(descend(pc)), sa.args)
	c2 = [to_print_node!(descend(pc),v,k,nothing) for (k,v) in sa.kwargs if !startswith(string(k),"__")] # skip "hidden" kwargs
	children = vcat(c1,c2)

	vf = get_versioned_function(sa)
	if vf !== nothing
		f = vf.f
		item_color = :green
	else
		f = Symbol("Function not specified")
		item_color = :red
	end

	if prefetch
		f = PrintFetched(f)
	end

	create_print_node(pc, name, h, f; children, item_color)
end



to_print_node(spec::Spec) = to_print_node!(PrintContext(), spec)


function print_spec(io::IO, spec::Spec; kwargs...)
	io = IOContext(io, :displaysize=>displaysize(io))
	tree = to_print_node(spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
