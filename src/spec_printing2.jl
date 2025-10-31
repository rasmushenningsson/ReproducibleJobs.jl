struct PrintNode2
	title::AnnotatedString
	indent::Int
	children::Vector{PrintNode2}
end
PrintNode2(context::PrintContext, title, children) = PrintNode2(title, context.depth*2, children)
PrintNode2(context::PrintContext, title) = PrintNode2(context, title, PrintNode2[])

AbstractTrees.children(x::PrintNode2) = x.children
function AbstractTrees.printnode(io::IO, x::PrintNode2)
	print(io, x.title)
end


build_print_node(context, value; prefix="") = build_print_node(context, convert(AnnotatedString,prefix), value)
build_print_node(value; kwargs...) = build_print_node(PrintContext(), value; kwargs...)


extend_prefix(prefix, new) = isempty(prefix) ? convert(AnnotatedString,new) : prefix*" "*new


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



function build_print_node(context::PrintContext, prefix::AnnotatedString, spec::Spec)
	# TODO: Hash context for duplicates etc.
	prefix = extend_prefix(prefix, styled"{green:$(spec.f)}")
	if spec.f isa AbstractPreprocess
		prefix = extend_prefix(prefix, styled"{bright_black:($(nameof(typeof(spec.f))))}")
	end
	if spec.op !== default_spec_op()
		prefix = extend_prefix(prefix, styled"{italic,bright_black:($(spec.op))}")
	end

	children = PrintNode2[]

	# TODO: Print ordinal instead. But then we need to keep track of that.
	h_short = spec.ro.h[1:6]

	if spec.ro.h in context.hashes
		# Seen before
		prefix = extend_prefix(prefix, styled"{blue:0x$(h_short)}")
	else
		# First time
		push!(context.hashes, spec.ro.h)

		prefix = extend_prefix(prefix, styled"{blue:0x$(h_short)}")
		
		context2 = descend(context)
		for a in spec.ro.value.args
			push!(children, build_print_node(context2, a))
		end
		for (k,v) in spec.ro.value.kwargs
			startswith(string(k), "__") && continue
			push!(children, build_print_node(context2, v; prefix=styled"{blue:$k:}"))
		end
	end
	PrintNode2(context, prefix, children)
end


function build_print_node(context::PrintContext, prefix::AnnotatedString, a::T) where T<:Union{AbstractArray,Tuple}
	# TODO: Hash context for duplicates etc.
	# TODO: Print on a single line if suitable types

	max_n = 10

	prefix = extend_prefix(prefix, styled"{magenta:$(_nameof(T))}")

	context2 = descend(context)
	children = PrintNode2[]
	for x in a[1:min(max_n,end)]
		push!(children, build_print_node(context2, x))
	end
	length(a) > max_n && push!(children, build_print_node(context2, PrintRaw(styled"{bright_black:...}")))
	PrintNode2(context, prefix, children)
end


function build_print_node(context::PrintContext, prefix::AnnotatedString, (k,v)::Pair{<:Union{String,Symbol}})
	build_print_node(context, extend_prefix(prefix, string(item_str(k), " =>")), v)
end


function build_print_node(context::PrintContext, prefix::AnnotatedString, ro::ReadOnly)
	build_print_node(context, prefix, ro.value)
end


function build_print_node(context::PrintContext, prefix::AnnotatedString, x)
	PrintNode2(context, extend_prefix(prefix, item_str(x)))
end


# function build_print_node(context::PrintContext, prefix::AnnotatedString, s::String)
# 	PrintNode2(context, extend_prefix(prefix, string('"',s,'"')))
# end

# function build_print_node(context::PrintContext, prefix::AnnotatedString, ::T) where T
# 	prefix = extend_prefix(prefix, string(nameof(T), " not implemented"))
# 	PrintNode2(context, prefix)
# end




function print_spec2(io::IO, spec::Spec; kwargs...)
	io = IOContext(io, :displaysize=>displaysize(io))
	tree = build_print_node(spec)
	AbstractTrees.print_tree(io, tree; kwargs...)
end
