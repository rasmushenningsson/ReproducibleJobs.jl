# TODO: revisit naming of functions and structs in this file...

struct HashByValue
	spec::Spec
end
preprocess_standard(x::HashByValue) = error("Did not expected to find Spec tagged as HashByValue during standard preprocessing.")

# This is for "tagging" specs to be evaluated
hash_by_value(x) = x
hash_by_value(spec::Spec) = HashByValue(spec)
hash_by_value(job::Job) = HashByValue(job.spec)


struct Barrier
	spec::Spec
end
Base.:(==)(a::Barrier, b::Barrier) = a.spec == b.spec
preprocess_standard(x::Barrier) = x


struct PreprocessHashByValue{F}
	f::F
	specs::Vector{Spec}
end


function (ph::PreprocessHashByValue)(x)
	if x isa HashByValue
		push!(ph.specs, x.spec)
		x = x.spec
	end
	ph.f(x)
end



_replace_evaluated(evaluated) = Base.Fix2(_replace_evaluated, evaluated)
_replace_evaluated(x, evaluated) = get(evaluated, x, x) # replaced evaluated specs by the value, and leaves everything else in place


function hash_by_value_eval(original::Barrier, specs::Pair{Barrier,<:Any}...)
	evaluated = IdDict((k.spec=>v for (k,v) in specs))

	# TODO: the code below can probably be simplified and/or use reusable components.

	ispec = _get_internal_spec(original.spec)
	vf = get_versioned_function(original.spec)

	args = (copy_nested(_replace_evaluated(evaluated), a) for a in ispec.args)
	kwargs = (copy_nested(_replace_evaluated(evaluated), k)=>copy_nested(_replace_evaluated(evaluated),v) for (k,v) in ispec.kwargs if k != :versionedfunction)

	create_spec(args...; kwargs..., original.spec.use_cache, versionedfunction=vf) # TODO: pass on deduplicator somehow
end



# TODO: make it possible to specify use_cache for inner and outer spec separately
function create_hash_by_value_spec(args...; deduplicator=default_deduplicator(), preprocess=deduplicator∘preprocess_standard, use_cache=true, kwargs...)
	specs = Spec[]
	ph = PreprocessHashByValue(preprocess, specs)

	inner_spec = create_spec(args...; deduplicator, preprocess=ph, use_cache, kwargs...)

	unique!(sort!(specs))

	if isempty(specs)
		inner_spec
	else
		create_spec(Barrier(inner_spec), (Barrier.(specs) .=> specs)...; deduplicator, preprocess, use_cache, versionedfunction=VersionedFunction(hash_by_value_eval,v"0.0.1"))
	end
end
