function is_preprocessing(spec::Spec)
	@assert spec.f !== nothing
	is_preprocessing(spec.f, spec)
end
is_preprocessing(ws::WrappedSpec) = is_preprocessing(get_sa(ws))

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::Spec) = is_preprocessing(f)
is_preprocessing(f) = false

# function get_dependencies(f::F, spec::Spec) where F
# 	deps = SpecUnion[]
# 	visit_dependencies(spec) do dep::SpecUnion
# 		f(dep) && push!(deps, dep)
# 	end
# 	return unique!(deps)
# end

# get_dependencies(spec::Spec) = get_dependencies(Returns(true), spec)

function get_dependencies(spec::Spec)
	deps = WrappedSpec[]
	# visit_dependencies(spec) do dep::WrappedSpec
	# 	push!(deps, dep)
	# end

	# DEBUG
	visit_dependencies(spec) do dep
		@assert dep isa WrappedSpec "Hmm. $(typeof(dep)) $(dep.f)"
		push!(deps, dep)
	end
	return unique!(deps)
end
