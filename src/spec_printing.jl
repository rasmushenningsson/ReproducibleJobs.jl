_nameof(::Type{T}) where T = Symbol(first(eachsplit(repr(T),'{')))
_nameof(::Type{<:NamedTuple}) = Symbol("NamedTuple") # is there a better way to avoid @NamedTuple?
_nameof(::Type{<:ReadOnlyArray{V,N,T}}) where {V,N,T} = _nameof(T)

_typenameof(x::T) where T = _nameof(T)


struct PrintContext
	pointers::Dict{Ptr{Nothing},Int} # Pointers mapping to how many times they have been seen
	pointer_to_ordinal::Dict{Ptr{Nothing},Int} # Pointers seen at least twice, mapping to an ordinal
	depth::Int
	line_length::Int
end
PrintContext(; line_length=80) = PrintContext(Dict{Ptr{Nothing},Int}(), Dict{Ptr{Nothing},Int}(), 0, line_length)

function add_pointer!(pc::PrintContext, p::Ptr{Nothing})
	n = get(pc.pointers, p, 0)
	pc.pointers[p] = n+1
	n > 0 # return true if seen before
end


descend(pc::PrintContext) = PrintContext(pc.pointers, pc.pointer_to_ordinal, pc.depth+1, pc.line_length)



_materialize_string(x::AbstractString) = x


_get_pointer(x) = deduplication_pointer(x)
_get_pointer(x::ReadOnlyArray) = deduplication_pointer(parent(x))



struct PointerOridinal
	context::PrintContext
	p::Ptr{Nothing}
end
function _materialize_string(po::PointerOridinal)
	if po.context.pointers[po.p] > 1
		ordinal = get!(po.context.pointer_to_ordinal, po.p, length(po.context.pointer_to_ordinal)+1)
		styled"{blue:#$ordinal}"
	else
		nothing
	end
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


function _print_limited_string(f, io, max_n, items; prefix, sep, suffix)
	sep isa Function || (sep = Returns(sep))

	n_printed = 0
	print(io, prefix)
	n_printed += length(prefix)

	n_remaining = max_n - length(prefix) - length(suffix)
	n_remaining = max(n_remaining, 10) # Print at least 10 chars of content

	n_items = length(items)

	curr::Union{String,AnnotatedString} = ""
	for (i,x) in enumerate(items)
		curr *= f(x)
		i != n_items && (curr *= sep(i))

		len = length(curr)
		if len < n_remaining-3
			# We are sure to fit the current string, so we can print it immediately
			print(io, curr)
			curr = ""
			n_printed += len
			n_remaining -= len
		elseif len > n_remaining
			break # No need to continue, the remainder will not fit
		end
		# Continue extending curr because we are not sure what will fit and whether to add ellipsis or not
	end

	if !isempty(curr)
		len = length(curr)
		if len > n_remaining # Cut string and add ellipsis if it doesn't fit
			curr = first(curr, n_remaining-3) * "..."
			len = length(curr)
		end
		print(io, curr)
		n_printed += len
	end


	print(io, suffix)
	n_printed += length(suffix)

	n_printed
end


print_limited_string(io, max_n, v::AbstractVector) =
	_print_limited_string(item_str, io, max_n, v; prefix="[", sep=", ", suffix="]")

print_limited_string(io, max_n, s::T) where T<:AbstractSet =
	_print_limited_string(item_str, io, max_n, s; prefix=styled"{magenta:$(_nameof(T))}([", sep=", ", suffix="])")

print_limited_string(io, max_n, d::T) where T<:AbstractDict =
	_print_limited_string(dict_item_str, io, max_n, d; prefix=styled"{magenta:$(_nameof(T))}(", sep=", ", suffix=")")

function print_limited_string(io, max_n, tup::Tuple)
	suffix = length(tup) == 1 ? ",)" : ")"
	_print_limited_string(item_str, io, max_n, tup; prefix="(", sep=", ", suffix)
end

print_limited_string(io, max_n, nt::NamedTuple) =
	_print_limited_string(nt_item_str, io, max_n, pairs(nt); prefix="(; ", sep=", ", suffix=")")


function print_limited_string(io, max_n, s::AbstractString)
	if length(s) > max_n
		s = first(s, max(3, max_n-3)) * "..."
	end
	print(io, s)
	length(s)
end


function _permuted_array_sep(p::T, i) where T<:Tuple
	n = length(p)
	for (k,x) in enumerate(reverse(p))
		mod(i, x) == 0 && return ';'^(n-k+1+(k!=n)) * ' ' # complicated rules for how many ; to use to separate between dimensions
	end
	" "
end
_permuted_array_sep(sz) = i->_permuted_array_sep(cumprod(sz), i)

function print_limited_string(io, max_n, a::AbstractArray{T,N}) where {T,N} # For matrices and higher-dimensional tensors
	pa = PermutedDimsArray(a, (2,1,(3:N)...)) # Print as row, column, trailing
	sz = size(pa)
	_print_limited_string(item_str, io, max_n, pa; prefix="[", sep=_permuted_array_sep(sz), suffix="]")
end



struct LimitedString
	x::Any
end
function print_limited_string(io, max_n, ls::LimitedString)
	print_limited_string(io, max_n, ls.x)
end


const PrintTitleElement = Union{String, AnnotatedString, PointerOridinal, LimitedString}

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
		if item isa PointerOridinal
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
		first || print(io, ' ')

		if item isa LimitedString
			max_n = div(n_chars_remaining, n_limited, RoundUp)
			len = print_limited_string(io, max_n, item)
			n_limited -= 1
			n_chars_remaining -= len
		else
			print(io, item)
		end

		first = false
	end
end

AbstractTrees.children(pn::PrintNode) = pn.children


function extend_title!(pn::PrintNode, new)
	@assert isempty(pn.children) "Cannot change title after node has children"
	push!(pn.title.items, new)
	pn
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

_should_collapse(::Type{<:SpecUnion}; nested) = false

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


function extend_print_node!(pn::PrintNode, spec::T) where T<:SpecUnion
	# Special handling of `get_cached`, to make things more compact
	suffix = ""

	sa = get_sa(spec)

	if sa.f == compoundresult_sub
		sub = only(sa.args[2:end])
		suffix = styled"{green,light:(cached:$sub)}"
		sa = sa.args[1]::SpecArgs # unwrap to `get_cached`
		@assert sa.f == get_cached
		sa = sa.args[1]::SpecArgs # unwrap fully
	elseif sa.f == compoundresult_keys
		suffix = styled"{green,light:(cached keys)}"
		sa = sa.args[1]::SpecArgs # unwrap to `get_cached`
		@assert sa.f == get_cached
		sa = sa.args[1]::SpecArgs # unwrap fully
	elseif sa.f == get_cached
		suffix = styled"{green,light:(cached)}"
		sa = sa.args[1]::SpecArgs # unwrap the spec
	end

	# Standard handling

	extend_title!(pn, styled_function_name(sa.f))
	# if spec.op !== default_spec_op()
	# 	extend_title!(pn, styled"{bright_black,light:($(spec.op))}")
	# end
	if T !== SpecArgs
		extend_title!(pn, styled"{bright_black,light:($T)}")
	end

	isempty(suffix) || extend_title!(pn, suffix)

	p = _get_pointer(sa)
	@assert p !== C_NULL
	extend_title!(pn, PointerOridinal(pn.context, p))

	if !add_pointer!(pn.context, p)
		# First time we see this item
		context2 = descend(pn.context)
		for a in sa.args
			push!(pn.children, build_print_node(context2, a))
		end
		for (k,v) in pairs(sa.kwargs)
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

	p = _get_pointer(a)
	@assert p !== C_NULL
	p !== nothing && extend_title!(pn, PointerOridinal(pn.context, p))

	if p === nothing || !add_pointer!(pn.context, p)
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

	p = _get_pointer(x)
	@assert p !== C_NULL
	extend_title!(pn, PointerOridinal(pn.context, p))

	if !add_pointer!(pn.context, p)
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


function print_spec(io::IO, spec::SpecUnion; kwargs...)
	context = PrintContext(; line_length=displaysize(io)[2])
	tree = build_print_node(context, spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
