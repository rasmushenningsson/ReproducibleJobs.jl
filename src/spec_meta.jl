function is_preprocessing(sa::SpecArgs)
	@assert sa.f !== nothing
	is_preprocessing(sa.f, sa)
end
is_preprocessing(spec::Spec) = is_preprocessing(_get_spec_args(spec))

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::SpecArgs) = is_preprocessing(f)
is_preprocessing(f) = false

function get_dependencies(f::F, sa::SpecArgs) where F
	deps = Spec[]
	visit_specs(sa) do dep::Spec
		f(dep.op) && push!(deps, dep)
	end
	return unique!(deps)
end

get_dependencies(sa::SpecArgs) = get_dependencies(Returns(true), sa)
