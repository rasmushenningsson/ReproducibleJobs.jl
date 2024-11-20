is_preprocessing(spec::Spec) = is_preprocessing(get_versioned_function(spec).f, spec)

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::Spec) = is_preprocessing(f)
is_preprocessing(f) = false


get_dependencies(spec::Spec) = get_dependencies(typeof(get_versioned_function(spec).f), spec)

# This can be customized to tell which specs should be fetched before computing
function get_dependencies(::Type{F}, spec::Spec) where F
	deps = Spec[]
	visit_dependencies(spec) do dep
		push!(deps, dep)
	end
	unique!(deps)
end
