function is_preprocessing(spec::Spec)
	@assert spec.f !== nothing
	is_preprocessing(spec.f, spec)
end

# One of these can be customized to tell that a function is preprocessing a spec
is_preprocessing(f, ::Spec) = is_preprocessing(f)
is_preprocessing(f) = false


function get_dependencies(spec::Spec)
	@assert spec.f !== nothing
	get_dependencies(spec.f, spec)
end

# This can be customized to tell which specs should be fetched before computing
function get_dependencies(f::F, spec::Spec) where F
	if is_preprocessing(f)
		return Spec[]
	else
		deps = Spec[]
		visit_dependencies(spec) do dep
			push!(deps, dep)
		end
		return unique!(deps)
	end
end
