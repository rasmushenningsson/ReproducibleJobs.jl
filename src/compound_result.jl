struct CompoundResult
	children::Vector{Pair{String,Any}}
end
function CompoundResult(; kwargs...)
	children = Pair{String,Any}[]
	for (k,v) in kwargs
		push!(children, String(k) => v)
	end
	CompoundResult(children)
end



function get_subresult(cr::CompoundResult, sub::Union{Nothing,AbstractVector}; return_keys::Bool=false)
	return_keys && return first.(cr.children)

	if sub === nothing || isempty(sub)
		# TODO: error instead?
		# return first.(cr.children) # return keys
		throw(ArgumentError("Cannot retrieve CompoundResult directly, sub-result must be specified."))
	end

	ks = first(sub)

	for (k,v) in cr.children
		if k == ks # found
			if v isa CompoundResult
				return get_subresult(v, @view(sub[2:end]); return_keys)
			else
				return_keys && throw(ArgumentError("return_keys can only be used on CompoundResults."))
				@assert length(sub)==1
				return v
			end
		end
	end

	throw(KeyError(ks))
end

# Base.copy(cr::CompoundResult) = cr # TODO: REMOVE THIS, JUST TEMPORARILY NEEDED DURING REFACTORING

