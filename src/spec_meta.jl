function is_preprocessing(sa::SpecArgs)
	@assert sa.f !== nothing
	is_preprocessing(sa.f, sa)
end
is_preprocessing(ws::WrappedSpec) = is_preprocessing(get_sa(ws))

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::SpecArgs) = is_preprocessing(f)
is_preprocessing(f) = false

# function get_dependencies(f::F, sa::SpecArgs) where F
# 	deps = WrappedSpec[]
# 	visit_dependencies(sa) do dep::WrappedSpec
# 		f(dep) && push!(deps, dep)
# 	end
# 	return unique!(deps)
# end

# get_dependencies(sa::SpecArgs) = get_dependencies(Returns(true), sa)

function get_dependencies(sa::SpecArgs)
	deps = WrappedSpec[]
	visit_dependencies(sa) do dep::WrappedSpec
		push!(deps, dep)
	end
	return unique!(deps)
end
