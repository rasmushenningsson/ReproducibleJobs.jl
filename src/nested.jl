function visit_nested(f, pred, a::Array)
	for x in a
		pred(x) && visit_nested(f, pred, x) # pred let us handle e.g. an Array{Array{Int}} that we do not need to traverse when looking for Specs
	end
end
function visit_nested(f, pred, d::Dict)
	for (k,v) in d
		pred(k) && visit_nested(f, pred, k)
		pred(v) && visit_nested(f, pred, v)
	end
end
function visit_nested(f, pred, t::Tuple)
	for x in t
		pred(x) && visit_nested(f, pred, x)
	end
end
function visit_nested(f, pred, (k,v)::Pair)
	pred(k) && visit_nested(f, pred, k)
	pred(v) && visit_nested(f, pred, v)
end

copy_nested(f,x) = f(x)
copy_nested(f,a::Array) = f([copy_nested(f,x) for x in a]) # NB: preserves dims of array, might change eltype
copy_nested(f,d::Dict) = f(Dict((copy_nested(f,k)=>copy_nested(f,v) for (k,v) in d)))
copy_nested(f,t::Tuple) = copy_nested.(f, t)
copy_nested(f,(k,v)::Pair) = copy_nested(f, k)=>copy_nested(f, v)
