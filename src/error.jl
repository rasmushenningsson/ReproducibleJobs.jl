"""
    error_spec(args...) -> Job

Create a [`Job`](@ref) that throws an error with the given arguments when computed.
Useful together with [`ifelse_spec`](@ref).
"""
error_spec(args...) = create_spec(error, args...; __version=v"0.1.0")
