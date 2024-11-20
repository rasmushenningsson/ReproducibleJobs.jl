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
