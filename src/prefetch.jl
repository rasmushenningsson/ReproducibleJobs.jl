function fetched(spec::Spec)
	ispec = _get_internal_spec(spec)
	any(isequal(:__fetched=>true), ispec.kwargs) && return spec

	kwargs2 = sort!(vcat(ispec.kwargs, :__fetched=>true); by=first)
	ispec2 = InternalSpec(ispec.args, kwargs2)

	# ispec2 = deduplicator(ispec2)
	ispec2 = default_deduplicator()(ispec2) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere

	Spec(ispec2, spec.use_cache)
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

	ispec = _get_internal_spec(original.spec)
	vf = get_versioned_function(original.spec)

	args = (copy_nested(_replace_fetched(fetched), a) for a in ispec.args)
	kwargs = (copy_nested(_replace_fetched(fetched), k)=>copy_nested(_replace_fetched(fetched),v) for (k,v) in ispec.kwargs if k != :__versionedfunction)

	# TODO: We need to ensure the __preprocess_spec is no longer here.
	#       But that seems like the job of the caller really.

	create_spec(args...; kwargs..., original.spec.use_cache, __versionedfunction=vf) # TODO: pass on deduplicator somehow
end


_process_fetched(deduplicator, fetched::Vector{Spec}) = x->_process_fetched(deduplicator, fetched, x)
function _process_fetched(deduplicator, fetched::Vector{Spec}, spec::Spec)
	if any(isequal(:__fetched=>true), _get_internal_spec(spec).kwargs)
		# remove __fetched from the spec and push it to the list of specs to process
		# TODO: Make some utlity function for this!?
		is = _get_internal_spec(spec)
		kw = filter(!isequal(:__fetched=>true), is.kwargs) # NB: keeps sorting
		is = deduplicator(InternalSpec(is.args, kw))
		spec2 = Spec(is, spec.use_cache)
		push!(fetched, spec2)
		spec2
	else
		spec
	end
end
_process_fetched(::Any, ::Vector{Spec}, x::Any) = x


function setup_prefetching_spec(args, kwargs; use_cache, deduplicator=default_deduplicator()) # TODO: ensure deduplicator is actually passed
	fetched = Spec[]

	args = copy_nested(_process_fetched(deduplicator, fetched), args)
	kwargs = copy_nested(_process_fetched(deduplicator, fetched), kwargs)
	# sort!(kwargs; by=first) # Not needed, the copy_nested above cannot change the order
	ispec = deduplicator(InternalSpec(args, kwargs))
	original = barrier(Spec(ispec, use_cache))

	create_spec(original, (barrier.(fetched) .=> fetched)...; deduplicator, use_cache, __versionedfunction=VersionedFunction(replace_fetched,v"0.0.1"))
end
