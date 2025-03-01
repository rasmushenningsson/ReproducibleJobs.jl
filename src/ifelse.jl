function ifelse_eval(cond, x, y; upstream=nothing)
	cond isa Spec && (cond = upstream[cond])
	cond ? x : y
end

is_preprocessing(::typeof(ifelse_eval)) = true
function get_dependencies(::typeof(ifelse_eval), spec::Spec)
	cond = spec.args[1]
	cond isa Spec ? [cond] : Spec[]
end

ifelse_spec(cond, x, y) =
	create_spec(ifelse_eval, cond, x, y)

ifelse_job(args...) = Job(ifelse_spec(args...))
