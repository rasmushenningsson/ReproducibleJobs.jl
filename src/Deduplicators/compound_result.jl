struct CompoundResult{T}
	keys::ROVec{String}
	values::Vector{T}
end
function CompoundResult(; kwargs...)
	k = ReadOnlyVector(collect(String.(keys(kwargs))))
	v = collect(values(kwargs))
	CompoundResult(k, v)
end

get_keys(cr::CompoundResult) = cr.keys
function get_subresult(cr::CompoundResult, sub::String)
	for (k,v) in zip(cr.keys, cr.values)
		if k == sub # found
			v isa CompoundResult && error("Nested CompoundResults are not (yet?) implemented.")
			return v
		end
	end
	throw(KeyError(sub))
end
