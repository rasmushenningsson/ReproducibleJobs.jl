_nameof(::Type{T}) where T = Symbol(first(eachsplit(repr(T),'{')))
_nameof(::Type{<:NamedTuple}) = Symbol("NamedTuple") # is there a better way to avoid @NamedTuple?
_nameof(::Type{<:ReadOnlyArray{V,N,T}}) where {V,N,T} = _nameof(T)

_typenameof(x::T) where T = _nameof(T)


struct PrintContext
	hashes::Set{String} # hashes seen at least once
	duplicates::Dict{String,Int} # hashes seen at least twice, mapping to an ordinal
	depth::Int
	line_length::Int
end
PrintContext(; line_length=80) = PrintContext(Set{String}(), Dict{String,Int}(), 0, line_length)

descend(pc::PrintContext) = PrintContext(pc.hashes, pc.duplicates, pc.depth+1, pc.line_length)



mutable struct PrintNode
	context::PrintContext
	title::AnnotatedString
	h::String
	children::Vector{PrintNode}
end
PrintNode(context, title) = PrintNode(context, title, "", PrintNode[])
PrintNode(context) = PrintNode(context, "")

AbstractTrees.children(x::PrintNode) = x.children
function AbstractTrees.printnode(io::IO, x::PrintNode)
	print(io, x.title)
	ordinal = get(x.context.duplicates, x.h, 0)
	ordinal > 0 && print(io, styled" {blue:#$ordinal}")
end


function extend_title!(pn::PrintNode, new)
	@assert isempty(pn.children) "Cannot change title after node has children"
	pn.title = isempty(pn.title) ? convert(AnnotatedString,new) : pn.title*" "*new
end

function set_hash!(pn::PrintNode, h)
	@assert isempty(pn.children) "Cannot set hash after node has children"
	@assert isempty(pn.h) "Hash already set"
	pn.h = h
end


chars_remaining(pn::PrintNode) = pn.context.line_length - pn.context.depth*3 - length(pn.title) - !isempty(pn.title)


function _limited_string(f, max_n, items; prefix, sep, suffix)
	parts = Union{String,AnnotatedString}[prefix]
	n_remaining = max_n - length(prefix) - length(suffix)
	n_remaining = max(n_remaining, 10) # We need to print something...

	sep_len = length(sep)

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

nt_item_str((k,v)::Pair) = nt_key_str(k) * "=" * item_str(v)
dict_item_str((k,v)::Pair) = dict_key_str(k) * "=>" * item_str(v)

limited_string(max_n, v::AbstractVector; kwargs...) =
	_limited_string(item_str, max_n, v; prefix="[", sep=", ", suffix="]", kwargs...)

limited_string(max_n, s::T; kwargs...) where T<:AbstractSet =
	_limited_string(item_str, max_n, s; prefix=styled"{magenta:$(_nameof(T))}([", sep=", ", suffix="])", kwargs...)

limited_string(max_n, d::T; kwargs...) where T<:AbstractDict =
	_limited_string(dict_item_str, max_n, d; prefix=styled"{magenta:$(_nameof(T))}(", sep=", ", suffix=")", kwargs...)

function limited_string(max_n, tup::Tuple; kwargs...)
	suffix = length(tup) == 1 ? ",)" : ")"
	_limited_string(item_str, max_n, tup; prefix="(", sep=", ", suffix, kwargs...)
end

limited_string(max_n, nt::NamedTuple; kwargs...) =
	_limited_string(nt_item_str, max_n, pairs(nt); prefix="(; ", sep=", ", suffix=")", kwargs...)


function limited_string(max_n, s::AbstractString)
	length(s) <= max_n && return s
	first(s, max(3, max_n-3)) * "..."
end


function limited_string(max_n, a::AbstractArray) # For matrices and higher-dimensional tensors
	s = repr(x; context=(:compact=>true, :short=>true))
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

_fix_suffix(::Base.Fix1) = "1"
_fix_suffix(::Base.Fix2) = "2"
_fix_suffix(::Base.Fix{N}) where N = "{$N}"
item_str(f::Base.Fix) = styled"Base.Fix" * _fix_suffix(f) * "(" * item_str(f.f) * ", " * item_str(f.x) * ")"


item_str(ts::TimestampedFilePath) = styled"$(ts.path){bright_black:@$(Dates.unix2datetime(ts.timestamp))}"



styled_function_name(f) = styled"{green:$f}"
styled_function_name(p::AbstractPreprocess) = styled_function_name(p.f) * styled" {bright_black:($(nameof(typeof(p))))}"
styled_function_name(p::Preprocess{false}) = styled_function_name(p.f) * styled" {bright_black:(Preprocess (late))}"


function extend_print_node!(pn::PrintNode, spec::Spec; suffix_space=0)
	# Special handling of `get_cached`, to make things more compact
	suffix = ""
	if spec.f == get_cached
		suffix = "(cached"
		length(spec.args)>=2 && (suffix = suffix*':'*spec.args[2])
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

	set_hash!(pn, spec.ro.h)

	if spec.ro.h in pn.context.hashes
		# Seen before
		get!(pn.context.duplicates, spec.ro.h, length(pn.context.duplicates)+1)
	else
		# First time
		push!(pn.context.hashes, spec.ro.h)

		context2 = descend(pn.context)
		for a in spec.ro.value.args
			push!(pn.children, build_print_node(context2, a))
		end
		for (k,v) in spec.ro.value.kwargs
			startswith(string(k), "__") && continue
			push!(pn.children, build_print_node(context2, v; prefix=styled"{blue:$k:}"))
		end
	end
	pn
end


function extend_print_node_collapsed!(pn::PrintNode, a::T; suffix_space=0) where T
	extend_title!(pn, limited_string(chars_remaining(pn)-suffix_space, a))
	pn
end

function extend_print_node_expanded!(f, pn::PrintNode, a::T; unwrap=identity) where T
	max_n = 20
	extend_title!(pn, styled"{magenta:$(_nameof(T))}")

	context2 = descend(pn.context)
	for (i,x) in enumerate(unwrap(a))
		i > max_n && break
		val,prefix = f(x)
		push!(pn.children, build_print_node(context2, val; prefix))
	end
	length(a) > max_n && push!(pn.children, build_print_node(context2, PrintRaw(styled"{bright_black:...}")))
	pn
end
extend_print_node_expanded!(pn, x) = extend_print_node_expanded!(x->(x,""), pn, x)
extend_print_node_expanded!(pn, x::NamedTuple) = extend_print_node_expanded!(p->(p[2],nt_key_str(p[1])*" ="), pn, x; unwrap=pairs)
extend_print_node_expanded!(pn, x::AbstractDict{<:Union{String,Symbol,Char,Number,DataType}}) =
	extend_print_node_expanded!(p->(p[2],dict_key_str(p[1]) * " =>"), pn, x)


function extend_print_node!(pn::PrintNode, x::T; suffix_space=0) where T<:Union{<:Tuple,<:NamedTuple}
	if _should_collapse(T)
		extend_print_node_collapsed!(pn, x; suffix_space)
	else
		extend_print_node_expanded!(pn, x)
	end
end


function extend_print_node!(pn::PrintNode, x::T; suffix_space=0) where T<:Union{<:AbstractArray,<:AbstractSet,<:AbstractDict}
	if _should_collapse(eltype(T))
		extend_print_node_collapsed!(pn, x; suffix_space)
	else
		extend_print_node_expanded!(pn, x)
	end
end


function extend_print_node!(pn::PrintNode, (k,v)::Pair{<:Union{String,Symbol,Char,Number,DataType}}; suffix_space=0)
	extend_title!(pn, item_str(k)*" =>")
	extend_print_node!(pn, v)
end

function extend_print_node!(pn::PrintNode, (k,v)::T; suffix_space=0) where T<:Pair
	extend_title!(pn, styled"{magenta:$(_nameof(T))}")
	context2 = descend(pn.context)
	push!(pn.children, build_print_node(context2, k))
	push!(pn.children, build_print_node(context2, v))
	pn
end




function extend_print_node!(pn::PrintNode, r::AbstractRange; suffix_space=0) # This is need to not dispatch to the AbstractArray case
	extend_title!(pn, limited_string(chars_remaining(pn)-suffix_space, item_str(r)))
	pn
end



function extend_print_node!(pn::PrintNode, ro::ReadOnly{T}; suffix_space=0) where T
	set_hash!(pn, ro.h)
	if ro.h in pn.context.hashes
		# Seen before
		get!(pn.context.duplicates, ro.h, length(pn.context.duplicates)+1)
		extend_title!(pn, styled"{magenta:$(_nameof(T))}")
	else
		# First time
		push!(pn.context.hashes, ro.h)
		# extend_title!(pn, limited_string(chars_remaining(pn)-4, item_str(ro.value))) # make some space for ordinal at end
		extend_print_node!(pn, ro.value; suffix_space=suffix_space+5)
	end
	pn
end


function extend_print_node!(pn::PrintNode, x; suffix_space=0)
	extend_title!(pn, limited_string(chars_remaining(pn)-suffix_space, item_str(x)))
	pn
end




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
