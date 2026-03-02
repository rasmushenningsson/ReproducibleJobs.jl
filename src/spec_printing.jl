_nameof(::Type{T}) where T = Symbol(first(eachsplit(repr(T),'{')))
_nameof(::Type{<:NamedTuple}) = Symbol("NamedTuple") # is there a better way to avoid @NamedTuple?
_nameof(::Type{<:ReadOnlyArray{V,N,T}}) where {V,N,T} = _nameof(T)

_typenameof(x::T) where T = _nameof(T)


struct PrintContext
	hashes::Dict{Deduplicators.Hash,Int} # Hashes mapping to how many times they have been seen
	hash_ordinals::Dict{Deduplicators.Hash,Int} # hashes seen at least twice, mapping to an ordinal
	depth::Int
	line_length::Int
end
PrintContext(; line_length=80) = PrintContext(Dict{Deduplicators.Hash,Int}(), Dict{Deduplicators.Hash,Int}(), 0, line_length)

function add_hash!(pc::PrintContext, h::Deduplicators.Hash)
	n = get(pc.hashes, h, 0)
	pc.hashes[h] = n+1
	n > 0 # return true if seen before
end


descend(pc::PrintContext) = PrintContext(pc.hashes, pc.hash_ordinals, pc.depth+1, pc.line_length)



_materialize_string(x::AbstractString) = x


struct HashOridinal
	context::PrintContext
	h::Deduplicators.Hash
end
function _materialize_string(ho::HashOridinal)
	if ho.context.hashes[ho.h] > 1
		ordinal = get!(ho.context.hash_ordinals, ho.h, length(ho.context.hash_ordinals)+1)
		styled"{blue:#$ordinal}"
	else
		nothing
	end
end


struct LimitedString
	x::Any
end
_materialize_string(ls::LimitedString; max_n::Int) = limited_string(max_n, ls.x)


const PrintTitleElement = Union{String, AnnotatedString, HashOridinal, LimitedString}

struct PrintTitle
	items::Vector{PrintTitleElement}
end
PrintTitle() = PrintTitle([])
PrintTitle(x::PrintTitleElement) = PrintTitle(PrintTitleElement[x])




mutable struct PrintNode
	context::PrintContext
	title::PrintTitle
	children::Vector{PrintNode}
end
PrintNode(context, title::PrintTitle) = PrintNode(context, title, PrintNode[])
PrintNode(context, title) = PrintNode(context, PrintTitle(title))
PrintNode(context) = PrintNode(context, PrintTitle())

function Base.show(io::IO, pn::PrintNode)
	# gather items and figure out remaining space
	n_chars_remaining = pn.context.line_length - pn.context.depth*3
	n_limited = 0
	items = PrintTitleElement[]
	for item in pn.title.items
		if item isa HashOridinal
			item = _materialize_string(item)
		end
		if item isa AbstractString
			n_chars_remaining -= length(item)
		elseif item isa LimitedString
			n_limited += 1
		end
		item !== nothing && push!(items, item)
	end
	n_chars_remaining -= length(items)-1 # adjust for spaces between items

	# print
	first = true
	for item in items
		if item isa LimitedString
			max_n = div(n_chars_remaining, n_limited, RoundUp)
			item = _materialize_string(item; max_n)
			n_limited -= 1
			n_chars_remaining -= length(item)
		end

		first || print(io, ' ')
		print(io, item)
		first = false
	end
end

AbstractTrees.children(pn::PrintNode) = pn.children


function extend_title!(pn::PrintNode, new)
	@assert isempty(pn.children) "Cannot change title after node has children"
	push!(pn.title.items, new)
	pn
end

function _limited_string(f, max_n, items; prefix, sep, suffix)
	parts = Union{String,AnnotatedString}[prefix]
	n_remaining = max_n - length(prefix) - length(suffix)
	n_remaining = max(n_remaining, 10) # We need to print something...

	# Convert enough items to strings
	n_items = length(items)
	for (i,x) in enumerate(items)
		s = f(x) * (i != n_items ? sep : "") # Skip separator for the last item
		push!(parts, s)
		n_remaining -= length(s)
		n_remaining<=0 && break
	end

	if n_remaining>=0 && length(parts) == length(items)+1 # +1 due to the prefix string in parts
		# The whole string fits!
		push!(parts, suffix)
	else
		# We need to cut something off
		n_remaining -= 3 # we need space for ellipsis

		while n_remaining<0
			s = pop!(parts)
			n_remaining += length(s)
			if n_remaining > 0
				push!(parts, AnnotatedString(first(s,n_remaining)))
				n_remaining = 0
			end
			n_remaining == 0 && break
		end

		push!(parts, "...", suffix)
	end
	join(parts)
end

nt_key_str(k) = styled"{blue:$k}"
dict_key_str(k) = styled"{blue:$k}"
array_key_str(::Any) = "" # Used for Vectors
function array_key_str(ci::CartesianIndex) # Used for Arrays of dim >= 2
	str = join(Tuple(ci),',')
	styled"{blue:$str:}"
end

nt_item_str((k,v)::Pair) = nt_key_str(k) * "=" * item_str(v)
dict_item_str((k,v)::Pair) = dict_key_str(k) * "=>" * item_str(v)

limited_string(max_n, v::AbstractVector) =
	_limited_string(item_str, max_n, v; prefix="[", sep=", ", suffix="]")

limited_string(max_n, s::T) where T<:AbstractSet =
	_limited_string(item_str, max_n, s; prefix=styled"{magenta:$(_nameof(T))}([", sep=", ", suffix="])")

limited_string(max_n, d::T) where T<:AbstractDict =
	_limited_string(dict_item_str, max_n, d; prefix=styled"{magenta:$(_nameof(T))}(", sep=", ", suffix=")")

function limited_string(max_n, tup::Tuple)
	suffix = length(tup) == 1 ? ",)" : ")"
	_limited_string(item_str, max_n, tup; prefix="(", sep=", ", suffix)
end

limited_string(max_n, nt::NamedTuple) =
	_limited_string(nt_item_str, max_n, pairs(nt); prefix="(; ", sep=", ", suffix=")")


function limited_string(max_n, s::AbstractString)
	length(s) <= max_n && return s
	first(s, max(3, max_n-3)) * "..."
end


function limited_string(max_n, a::AbstractArray) # For matrices and higher-dimensional tensors
	# TODO: Improve how type info is written
	s = repr(a; context=(:compact=>true, :short=>true))
	limited_string(max_n, s)
end



struct PrintRaw{T<:AbstractString}
	raw::T
end



item_str(x::Any) = repr(x; context=(:compact=>true, :short=>true))

item_str(x::PrintRaw) = x.raw
item_str(s::Union{String,Symbol,Char,Number}) = repr(s)
item_str(::Missing) = styled"{italic,bright_black:missing}"


item_str(t::Tuple) = "(" * join(item_str.(t), ", ") * ")"


item_str(d::DataType) = styled"{cyan:$d}"

item_str(f::Function) = styled"{cyan:$f}"


_styled_name_fix(::Base.Fix1) = styled"{cyan:Base.Fix1}"
_styled_name_fix(::Base.Fix2) = styled"{cyan:Base.Fix2}"
@static if VERSION >= v"1.12.0"
	_styled_name_fix(::Base.Fix{N}) where N = styled"{cyan:Base.Fix\{$N\}}"
	item_str(f::Base.Fix) = _styled_name_fix(f) * "(" * item_str(f.f) * ", " * item_str(f.x) * ")"
else
	item_str(f::Union{Base.Fix1,Base.Fix2}) = _styled_name_fix(f) * "(" * item_str(f.f) * ", " * item_str(f.x) * ")"
end


item_str(r::Returns{T}) where T = styled"{cyan:Returns(}" * item_str(r.value) * styled"{cyan:)}"
function item_str(c::ComposedFunction{T1,T2}) where {T1,T2}
	if c.outer === !
		item_str(c.outer) * item_str(c.inner)
	else
		item_str(c.outer) * "∘" * item_str(c.inner)
	end
end



item_str(ts::TimestampedFilePath) = styled"$(ts.path){bright_black:@$(Dates.unix2datetime(ts.timestamp))}"


styled_function_name(f) = styled"{green:$f}"
styled_function_name(p::AbstractPreprocess) = styled_function_name(p.f) * styled" {bright_black:($(nameof(typeof(p))))}"
styled_function_name(p::Preprocess{false}) = styled_function_name(p.f) * styled" {bright_black:(Preprocess (late))}"



# Unions and fallback
function _should_collapse(::Type{T}; nested::Bool) where T
	T isa Union && return _should_collapse(T.a; nested) && _should_collapse(T.b; nested)
	return false
end

_should_collapse(::Type{Spec}; nested) = false

_should_collapse(::Type{AbstractRange}; nested) = true
function _should_collapse(::Type{T}; nested) where T<:Union{<:AbstractArray, <:AbstractDict, <:AbstractSet}
	nested ? false : _should_collapse(eltype(T); nested=true)
end

_should_collapse(::Type{T}; nested) where T<:Union{<:Number,String,Symbol,Char,DataType,Colon,Nothing,Missing,VersionNumber,Regex} = true
_should_collapse(::Type{T}; nested) where T<:Function = !(T isa UnionAll) # true for standard functions and false for e.g. Base.Fix with free parameters

_should_collapse(::Type{T}; nested) where T<:Union{<:Pair, <:Tuple, <:NamedTuple, <:Returns, <:ComposedFunction} =
	all(x->_should_collapse(x; nested), fieldtypes(T))

@static if VERSION >= v"1.12.0"
	_should_collapse(::Type{Base.Fix{N,F,T}}; nested) where {N,F,T} =
		_should_collapse(F; nested) && _should_collapse(T; nested)
else
	_should_collapse(::Type{Base.Fix1{F,T}}; nested) where {F,T} =
		_should_collapse(F; nested) && _should_collapse(T; nested)
	_should_collapse(::Type{Base.Fix2{F,T}}; nested) where {F,T} =
		_should_collapse(F; nested) && _should_collapse(T; nested)
end

_should_collapse(::Type{DataFrame}) = false


should_collapse(::Type{T}) where T = _should_collapse(T; nested=false)


function extend_print_node!(pn::PrintNode, spec::Spec)
	# Special handling of `get_cached`, to make things more compact
	suffix = ""
	if spec.f == get_cached
		suffix = "(cached"
		length(spec.args)>=2 && (suffix = suffix*':'*only(spec.args[2:end]))
		suffix *= ')'
		suffix = styled"{green,light:$suffix}"

		spec = spec.args[1]::Spec # unwrap the spec
	end

	# Standard handling

	extend_title!(pn, styled_function_name(spec.f))
	if spec.op !== default_spec_op()
		extend_title!(pn, styled"{bright_black,light:($(spec.op))}")
	end

	isempty(suffix) || extend_title!(pn, suffix)

	deduplicator = default_deduplicator() # TODO: Use from scheduler somehow?
	h = Deduplicators.lookup_hash(deduplicator, spec.sa)

	# set_hash!(pn, h)

	extend_title!(pn, HashOridinal(pn.context, h))

	if !add_hash!(pn.context, h)
		# First time we see this item
		context2 = descend(pn.context)
		for a in spec.sa.args
			push!(pn.children, build_print_node(context2, a))
		end
		for (k,v) in spec.sa.kwargs
			startswith(string(k), "__") && continue
			push!(pn.children, build_print_node(context2, v; prefix=styled"{blue:$k:}"))
		end
	end
	pn
end


extend_print_node_collapsed!(pn::PrintNode, a::T) where T = extend_title!(pn, LimitedString(a))

function extend_print_node_expanded!(f, pn::PrintNode, a::T; unwrap=identity) where T
	max_n = 20
	extend_title!(pn, styled"{magenta:$(_nameof(T))}")

	deduplicator = default_deduplicator() # TODO: Use from scheduler somehow?
	h = Deduplicators.lookup_hash(deduplicator, a)
	h !== nothing && extend_title!(pn, HashOridinal(pn.context,h))

	if h === nothing || !add_hash!(pn.context, h)
		# First time we see this item
		context2 = descend(pn.context)
		for (i,x) in enumerate(unwrap(a))
			i > max_n && break
			val,prefix = f(x)
			push!(pn.children, build_print_node(context2, val; prefix))
		end
		length(a) > max_n && push!(pn.children, build_print_node(context2, PrintRaw(styled"{bright_black:...}")))
	end

	pn
end
extend_print_node_expanded!(pn, x) = extend_print_node_expanded!(y->(y,""), pn, x)
extend_print_node_expanded!(pn, x::AbstractArray) = extend_print_node_expanded!(p->(p[2],array_key_str(p[1])), pn, x; unwrap=pairs)
extend_print_node_expanded!(pn, x::NamedTuple) = extend_print_node_expanded!(p->(p[2],nt_key_str(p[1])*" ="), pn, x; unwrap=pairs)
extend_print_node_expanded!(pn, x::AbstractDict{<:Union{String,Symbol,Char,Number,DataType}}) =
	extend_print_node_expanded!(p->(p[2],dict_key_str(p[1]) * " =>"), pn, x)


function extend_print_node!(pn::PrintNode, x::T) where T<:Union{<:Tuple,<:NamedTuple,<:AbstractArray,<:AbstractSet,<:AbstractDict}
	if should_collapse(T)
		extend_print_node_collapsed!(pn, x)
	else
		extend_print_node_expanded!(pn, x)
	end
end



function extend_print_node!(pn::PrintNode, (k,v)::Pair{<:Union{String,Symbol,Char,Number,DataType}})
	# extend_title!(pn, item_str(k)*" =>")
	extend_title!(pn, item_str(k))
	extend_title!(pn, "=>")
	extend_print_node!(pn, v)
end

function extend_print_node!(pn::PrintNode, (k,v)::T) where T<:Pair
	extend_title!(pn, styled"{magenta:$(_nameof(T))}")
	context2 = descend(pn.context)
	push!(pn.children, build_print_node(context2, k))
	push!(pn.children, build_print_node(context2, v))
	pn
end



# This is need to not dispatch to the AbstractArray case
extend_print_node!(pn::PrintNode, r::AbstractRange) = extend_title!(pn, LimitedString(item_str(r)))


# Returns, Fix, ComposedFunction - are these similar enough to share code?
function extend_print_node!(pn::PrintNode, x::Returns{T}) where T
	if should_collapse(T)
		extend_title!(pn, LimitedString(item_str(x)))
	else
		extend_title!(pn, styled"{cyan:Returns}")
		context2 = descend(pn.context)
		push!(pn.children, build_print_node(context2, x.value))
	end
	pn
end

@static if VERSION >= v"1.12.0"
	function extend_print_node!(pn::PrintNode, x::Base.Fix{N,F,T}) where {N,F,T}
		if should_collapse(F) && should_collapse(T)
			extend_title!(pn, LimitedString(item_str(x)))
		else
			extend_title!(pn, styled"{cyan:$(_nameof(Base.Fix{N}))}")
			context2 = descend(pn.context)
			push!(pn.children, build_print_node(context2, x.f))
			push!(pn.children, build_print_node(context2, x.x))
		end
		pn
	end
end

function extend_print_node!(pn::PrintNode, x::ComposedFunction{T1,T2}) where {T1,T2}
	if should_collapse(T1)
		if should_collapse(T2)
			extend_title!(pn, LimitedString(item_str(x)))
		else
			extend_title!(pn, LimitedString(item_str(x.outer)))
			extend_title!(pn, "∘")
			extend_print_node!(pn, x.inner)
		end
	else
		extend_title!(pn, "ComposedFunction")
		context2 = descend(pn.context)
		push!(pn.children, build_print_node(context2, x.outer))
		push!(pn.children, build_print_node(context2, x.inner))
	end
	pn
end


function extend_print_node!(pn::PrintNode, x::DataFrame)
	max_n = 20

	extend_title!(pn, styled"{magenta:DataFrame}")

	deduplicator = default_deduplicator() # TODO: Use from scheduler somehow?
	h = Deduplicators.lookup_hash(deduplicator, x)
	h !== nothing && extend_title!(pn, HashOridinal(pn.context,h))

	if h === nothing || !add_hash!(pn.context, h)
		context2 = descend(pn.context)
		for (i,(k,v)) in enumerate(pairs(eachcol(x)))
			if i > max_n
				push!(pn.children, build_print_node(context2, PrintRaw(styled"{bright_black:...}")))
				break
			end
			push!(pn.children, build_print_node(context2, v; prefix=styled"{blue:$k:}"))
		end
	end

	pn
end


extend_print_node!(pn::PrintNode, x) = extend_title!(pn, LimitedString(item_str(x)))




function build_print_node(context, value; prefix="")
	pn = PrintNode(context)
	isempty(prefix) || extend_title!(pn, prefix)
	extend_print_node!(pn, value)
end


function print_spec(io::IO, spec::Spec; kwargs...)
	context = PrintContext(; line_length=displaysize(io)[2])
	tree = build_print_node(context, spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
