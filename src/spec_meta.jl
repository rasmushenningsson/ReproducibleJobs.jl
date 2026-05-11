function is_preprocessing(spec::Spec)
	@assert spec.f !== nothing
	is_preprocessing(spec.f, spec)
end
is_preprocessing(sr::SpecRun) = is_preprocessing(get_spec(sr))
is_preprocessing(ref::SpecRef) = is_preprocessing(get_spec(ref))

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::Spec) = is_preprocessing(f)
is_preprocessing(f) = false

# function get_dependencies(f::F, spec::Spec) where F
# 	deps = SpecRef[]
# 	visit_dependencies(spec) do dep::SpecRef
# 		f(dep) && push!(deps, dep)
# 	end
# 	return unique!(deps)
# end

# get_dependencies(spec::Spec) = get_dependencies(Returns(true), spec)

function get_dependencies(spec::Spec)
	deps = SpecRef[]
	visit_dependencies(spec) do dep::SpecRef
		push!(deps, dep)
	end
	return unique!(deps)
end
get_dependencies(sr::SpecRun) = get_dependencies(sr.spec)
