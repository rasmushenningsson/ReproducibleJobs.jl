function ifelse_eval(spec::Spec, upstream::IdDict{Spec,Any})
	cond = spec.ro.value.args[1]
	cond isa Spec && (cond = upstream[cond])
	cond ? spec.ro.value.args[2] : spec.ro.value.args[3]
end

is_preprocessing(::typeof(ifelse_eval)) = true
function get_dependencies(::typeof(ifelse_eval), spec::Spec)
	deps = Spec[]
	cond = spec.ro.value.args[1]
	cond isa Spec && push!(deps, cond)
	deps
end

create_ifelse_spec(cond, x, y; kwargs...) =
	create_spec(cond, x, y; __versionedfunction=VersionedFunction(ifelse_eval,v"0.1.0"), kwargs...)
