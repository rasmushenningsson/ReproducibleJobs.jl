ifelse_eval(cond, x::Barrier, y::Barrier) = cond ? x.spec : y.spec
create_ifelse_spec(cond, x, y; kwargs...) =
	create_spec(cond, barrier(x), barrier(y); kwargs..., __versionedfunction=VersionedFunction(ifelse_eval,v"0.0.1"))
