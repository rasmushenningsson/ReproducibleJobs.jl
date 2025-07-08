function is_preprocessing(sa::SpecArgs)
	@assert sa.f !== nothing
	is_preprocessing(sa.f, sa)
end
is_preprocessing(spec::Spec) = is_preprocessing(_get_spec_args(spec))

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::SpecArgs) = is_preprocessing(f)
is_preprocessing(f) = false


# We should probably add an (optional) parameter `f` that will be applied to dependencies, e.g. forcing forwarding.
# And then not return deps with `op===nothing`. Because that's the most common case during preprocessing.
function get_dependencies(sa::SpecArgs)
	deps = Spec[]
	visit_dependencies(sa) do dep
		push!(deps, dep)
	end
	return unique!(deps)
end
get_dependencies(spec::Spec) = get_dependencies(_get_spec_args(spec))
