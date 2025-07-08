ifelse_impl(cond, x, y) = cond ? x : y
is_preprocessing(::typeof(ifelse_impl)) = true

ifelse_spec(cond, x, y) = create_spec(ifelse_impl, prefetch(cond), x, y)
ifelse_job(args...) = Job(ifelse_spec(args...))
