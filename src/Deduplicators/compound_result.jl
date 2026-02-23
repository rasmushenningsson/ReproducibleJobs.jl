abstract type AbstractCompoundResult end

struct CompoundResult{T} <: AbstractCompoundResult
	keys::ROVec{String}
	values::Vector{T}
end
function CompoundResult(; kwargs...)
	k = ReadOnlyVector(collect(String.(keys(kwargs))))
	v = collect(values(kwargs))
	CompoundResult(k, v)
end


struct WeakCompoundResult <: AbstractCompoundResult
	keys::ROVec{String}
	values::Vector{Any} # When loading from disk - we do not know the types, so we have Any here. Fix?
end
WeakCompoundResult(keys::ROVec{String}) = WeakCompoundResult(keys, Any[WeakRef() for _ in keys])


get_keys(cr::AbstractCompoundResult) = cr.keys
function get_subresult(cr::AbstractCompoundResult, sub::String)
	for (k,v) in zip(cr.keys, cr.values)
		if k == sub # found
			v isa AbstractCompoundResult && error("Nested CompoundResults are not (yet?) implemented.")
			return v
		end
	end
	throw(KeyError(sub))
end
