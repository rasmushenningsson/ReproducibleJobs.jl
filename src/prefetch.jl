function fetched(spec::Spec)
	sa = _get_spec_args(spec)
	any(isequal(:__fetched=>true), sa.kwargs) && return spec

	kwargs2 = sort!(vcat(sa.kwargs, :__fetched=>true); by=first)
	sa2 = SpecArgs(sa.args, kwargs2)

	# sa2 = deduplicator(sa2)
	sa2 = default_deduplicator()(sa2) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere

	Spec(sa2, spec.use_cache)
end

function fetched(x::Any)
	copy_nested(x) do y
		y isa Union{Spec,Job} ? fetched(y) : y
	end
end




_replace_fetched(fetched) = Base.Fix1(_replace_fetched, fetched)
_replace_fetched(fetched, x) = get(fetched, x, x) # replaced fetched specs by the value, and leaves everything else in place

# TODO: Find a better name
function replace_fetched(original::Barrier, specs::Pair{Barrier,<:Any}...)
	fetched = IdDict((k.spec=>v for (k,v) in specs))

	# TODO: the code below can probably be simplified and/or use reusable components.

	sa = _get_spec_args(original.spec)
	vf = get_versioned_function(original.spec)

	args = (copy_nested(_replace_fetched(fetched), a) for a in sa.args)
	kwargs = (copy_nested(_replace_fetched(fetched), k)=>copy_nested(_replace_fetched(fetched),v) for (k,v) in sa.kwargs if k != :__versionedfunction)

	create_spec(args...; kwargs..., original.spec.use_cache, __versionedfunction=vf) # TODO: pass on deduplicator somehow
end


_process_fetched(deduplicator, fetched::Vector{Spec}) = x->_process_fetched(deduplicator, fetched, x)

function _process_fetched(deduplicator, fetched::Vector{Spec}, spec::Spec)
	if any(isequal(:__fetched=>true), _get_spec_args(spec).kwargs)
		# remove __fetched from the spec and push it to the list of specs to process
		# TODO: Make some utlity function for this!?
		is = _get_spec_args(spec)
		kw = filter(!isequal(:__fetched=>true), is.kwargs) # NB: keeps sorting
		is = deduplicator(SpecArgs(is.args, kw))
		spec2 = Spec(is, spec.use_cache)
		push!(fetched, spec2)
		spec2
	else
		spec
	end
end
_process_fetched(::Any, ::Vector{Spec}, x::Any) = x


function setup_prefetching_spec(spec; deduplicator=default_deduplicator()) # TODO: ensure deduplicator is actually passed
	fetched = Spec[]

	sa = _get_spec_args(spec)
	args = copy_nested(_process_fetched(deduplicator, fetched), sa.args)
	kwargs = copy_nested(_process_fetched(deduplicator, fetched), sa.kwargs)
	filter!(!isequal(:__preprocess_spec=>VersionedFunction(setup_prefetching_spec,v"0.0.1")), kwargs)
	# sort!(kwargs; by=first) # Not needed, the copy_nested and filtering above cannot change the order
	sa2 = deduplicator(SpecArgs(args, kwargs))
	original = barrier(Spec(sa2, spec.use_cache))

	create_spec(original, (barrier.(fetched) .=> fetched)...; deduplicator, spec.use_cache, __versionedfunction=VersionedFunction(replace_fetched,v"0.0.1"))
end
