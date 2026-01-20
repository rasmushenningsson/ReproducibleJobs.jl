visit_nested(f, pred, x) = f(x)

# Hmm. Is this desired?
# visit_nested(f, pred, ro::ReadOnly) = visit_nested(f, pred, ro.value)
# NB: visit_nested should not go into ReadOnlys, they are considered "leaves"

function visit_nested(f, pred, a::Union{<:AbstractArray,<:Tuple,<:NamedTuple,<:AbstractSet})
	for x in a
		pred(x) && visit_nested(f, pred, x) # pred let us handle e.g. an Array{Array{Int}} that we do not need to traverse when looking for Specs
	end
end
function visit_nested(f, pred, d::AbstractDict)
	for (k,v) in d
		pred(k) && visit_nested(f, pred, k)
		pred(v) && visit_nested(f, pred, v)
	end
end
function visit_nested(f, pred, (k,v)::Pair)
	pred(k) && visit_nested(f, pred, k)
	pred(v) && visit_nested(f, pred, v)
end

# TODO: Move to package extension?
visit_nested(f, pred, a::AbstractSparseArray) = nothing


# TODO: Move to package extension?
# This considers a DataFrame as a collection of named vectors.
function visit_nested(f, pred, df::AbstractDataFrame)
	for x in eachcol(df)
		pred(x) && visit_nested(f, pred, x)
	end
end


@static if VERSION >= v"1.12.0"
	function visit_nested(f, pred, fix::Base.Fix{N}) where N
		pred(fix.f) && visit_nested(f, pred, fix.f)
		pred(fix.x) && visit_nested(f, pred, fix.x)
	end
else
	function visit_nested(f, pred, fix::Union{Base.Fix1, Base.Fix2})
		pred(fix.f) && visit_nested(f, pred, fix.f)
		pred(fix.x) && visit_nested(f, pred, fix.x)
	end
end



visit_nested(f, x) = visit_nested(f, Returns(true), x)


copy_nested(f,x) = f(x)

# NB: copy_nested should not go into ReadOnlys, they are considered "leaves"


copy_nested(f,r::AbstractRange) = f(r)
copy_nested(f,a::AbstractArray) = f([copy_nested(f,x) for x in a]) # NB: preserves dims of array, might change eltype
copy_nested(f,d::AbstractDict) = f(Dict((copy_nested(f,k)=>copy_nested(f,v) for (k,v) in d)))
copy_nested(f,s::AbstractSet) = f(Set((copy_nested(f,x) for x in s)))
copy_nested(f,t::Tuple) = copy_nested.(f, t)
copy_nested(f,nt::NamedTuple) = map(x->copy_nested(f,x), nt)
copy_nested(f,(k,v)::Pair) = copy_nested(f, k)=>copy_nested(f, v)

copy_nested(f,a::Adjoint) = Adjoint(copy_nested(f,parent(a)))
copy_nested(f,a::Transpose) = Transpose(copy_nested(f,parent(a)))

@static if VERSION >= v"1.12.0"
	function copy_nested(f, fix::Base.Fix{N}) where N
		Base.Fix{N}(copy_nested(f,fix.f), copy_nested(f,fix.x))
	end
else
	function copy_nested(f, fix::Base.Fix1)
		Base.Fix1(copy_nested(f,fix.f), copy_nested(f,fix.x))
	end
	function copy_nested(f, fix::Base.Fix2)
		Base.Fix2(copy_nested(f,fix.f), copy_nested(f,fix.x))
	end
end


# TODO: Move to package extension?
copy_nested(f,a::AbstractSparseArray) = f(a) # ensure that sparse matrices are not converted to dense

# TODO: Move to package extension?
# This considers a DataFrame as a collection of named vectors.
# Hmm. Not very good solution. Columns will be ReadOnly's, which are treated as scalars by the DataFrame constructor, creating a 1×N DataFrame.
# Maybe OK for now.
function copy_nested(f, df::AbstractDataFrame)
	# A hack to handle that putting ReadOnly's in DataFrames wraps them in Vectors of length 1
	if size(df,2)>0 && df[!,1] isa Vector{<:ReadOnly}
		# f(DataFrame((k=>ReadOnlyVector(f(only(v)).value) for (k,v) in pairs(eachcol(df)))...; copycols=false))
		f(DataFrame((k=>f(ReadOnlyVector(only(v).value)) for (k,v) in pairs(eachcol(df)))...; copycols=false))
	else
		f(DataFrame((k=>copy_nested(f,v) for (k,v) in pairs(eachcol(df)))...; copycols=false))
	end

end
