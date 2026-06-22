ifelse_impl(::Preprocessing, cond, x, y) = cond ? x : y

"""
    ifelse_spec(cond, x, y) -> Job

Create a preprocessing [`Job`](@ref) that selects `x` if `cond` is true, or `y` otherwise.
`cond` must be a `Job` that evaluates to a `Bool`. This is resolved during the forwarding
phase, enabling conditional spec trees.
"""
ifelse_spec(cond, x, y) = create_spec(Preprocess(ifelse_impl), fetched(cond), x, y)
