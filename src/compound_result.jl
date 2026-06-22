"""
    CompoundResult(; kwargs...)

A named collection of heterogeneous results from a single computation.

Used with [`cached`](@ref) to store multi-output computations on disk and load individual
sub-results without loading the entire result. Construct with keyword arguments where keys
become string names and values are the individual results.

# Examples
```julia
CompoundResult(; values, indices)
```

See also [`cached`](@ref).
"""
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
