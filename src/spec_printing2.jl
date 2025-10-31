mutable struct PrintNode2
	title::AnnotatedString
	indent::Int # Use to know how much space we have left on the line
	h::String
	children::Vector{PrintNode2}
end
PrintNode2(context, title) = PrintNode2(title, context.depth*3, "", PrintNode2[])
PrintNode2(context) = PrintNode2(context, "")

AbstractTrees.children(x::PrintNode2) = x.children
AbstractTrees.printnode(io::IO, x::PrintNode2) = print(io, x.title)


function extend_title!(pn::PrintNode2, new)
	@assert isempty(pn.children) "Cannot change title after node has children"
	pn.title = isempty(pn.title) ? convert(AnnotatedString,new) : pn.title*" "*new
end





struct PrintRaw{T<:AbstractString}
	raw::T
end



# item_str(x::T) where T = styled"{italic,shadow:$(nameof(T)) not implemented}"
# item_str(x::Any) = repr(x) # TODO: Print with 
function item_str(x::Any)
	io = IOBuffer()
	show(IOContext(io, :limit=>true, :compact=>true, :short=>true), x)
	String(take!(io))
end

item_str(x::PrintRaw) = x.raw
item_str(s::Union{String,Symbol,Bool,Number,Char}) = repr(s)
item_str(::Missing) = styled"{italic,bright_black:missing}"

item_str(d::DataType) = styled"{cyan:$d}"

item_str(f::Function) = styled"{cyan:$f}"

_fix_suffix(::Base.Fix1) = "1"
_fix_suffix(::Base.Fix2) = "2"
_fix_suffix(::Base.Fix{N}) where N = "{$N}"
item_str(f::Base.Fix) = styled"Base.Fix" * _fix_suffix(f) * "(" * item_str(f.f) * ", " * item_str(f.x) * ")"


item_str(ts::TimestampedFilePath) = styled"$(ts.path){bright_black:@$(Dates.unix2datetime(ts.timestamp))}"






function extend_print_node!(pn::PrintNode2, context::PrintContext, spec::Spec)
	# TODO: Hash context for duplicates etc.

	extend_title!(pn, styled"{green:$(spec.f)}")
	if spec.f isa AbstractPreprocess
		extend_title!(pn, styled"{bright_black:($(nameof(typeof(spec.f))))}")
	end
	if spec.op !== default_spec_op()
		extend_title!(pn, styled"{italic,bright_black:($(spec.op))}")
	end


	# TODO: Print ordinal instead. But then we need to keep track of that.
	h_short = spec.ro.h[1:6]

	if spec.ro.h in context.hashes
		# Seen before
		extend_title!(pn, styled"{blue:0x$(h_short)}")
	else
		# First time
		push!(context.hashes, spec.ro.h)

		extend_title!(pn, styled"{blue:0x$(h_short)}")
		
		context2 = descend(context)
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


function extend_print_node!(pn::PrintNode2, context::PrintContext, a::T) where T<:Union{AbstractArray,Tuple}
	# TODO: Hash context for duplicates etc.
	# TODO: Print on a single line if suitable types

	max_n = 10

	extend_title!(pn, styled"{magenta:$(_nameof(T))}")

	context2 = descend(context)
	for x in a[1:min(max_n,end)]
		push!(pn.children, build_print_node(context2, x))
	end
	length(a) > max_n && push!(pn.children, build_print_node(context2, PrintRaw(styled"{bright_black:...}")))
	pn
end


function extend_print_node!(pn::PrintNode2, context::PrintContext, (k,v)::Pair{<:Union{String,Symbol}})
	extend_title!(pn, string(item_str(k), " =>"))
	extend_print_node!(pn, context, v)
end


# TODO: Handle hashes?
function extend_print_node!(pn::PrintNode2, context::PrintContext, ro::ReadOnly)
	extend_print_node!(pn, context, ro.value)
end


function extend_print_node!(pn::PrintNode2, context::PrintContext, x)
	extend_title!(pn, item_str(x))
	pn
end



function build_print_node(context, value; prefix="")
	pn = PrintNode2(context)
	isempty(prefix) || extend_title!(pn, prefix)
	extend_print_node!(pn, context, value)
end


function print_spec2(io::IO, spec::Spec; kwargs...)
	io = IOContext(io, :displaysize=>displaysize(io))
	context = PrintContext()
	tree = build_print_node(context, spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
