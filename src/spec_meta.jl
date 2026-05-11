function is_preprocessing(sr::SpecRun)
	@assert sr.f !== nothing
	is_preprocessing(sr.f, sr)
end
is_preprocessing(ref::SpecRef) = is_preprocessing(get_sr(ref))

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::SpecRun) = is_preprocessing(f)
is_preprocessing(f) = false

# function get_dependencies(f::F, sr::SpecRun) where F
# 	deps = SpecRef[]
# 	visit_dependencies(sr) do dep::SpecRef
# 		f(dep) && push!(deps, dep)
# 	end
# 	return unique!(deps)
# end

# get_dependencies(sr::SpecRun) = get_dependencies(Returns(true), sr)

function get_dependencies(sr::SpecRun)
	deps = SpecRef[]
	visit_dependencies(sr) do dep::SpecRef
		push!(deps, dep)
	end
	return unique!(deps)
end
