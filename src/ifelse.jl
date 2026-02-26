ifelse_impl(::Preprocessing, cond, x, y) = cond ? x : y
ifelse_spec(cond::Bool, x, y) = create_spec(Preprocess(ifelse_impl), cond, x, y)
ifelse_spec(cond, x, y) = create_spec(Preprocess(ifelse_impl), fetched(cond), x, y)
ifelse_job(args...) = Job(ifelse_spec(args...))
