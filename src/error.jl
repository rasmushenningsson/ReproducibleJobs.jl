"""
    error_job(args...) -> Job

Create a [`Job`](@ref) that throws an error with the given arguments when computed.
Useful together with [`ifelse_job`](@ref).
"""
error_job(args...) = create_job(error, args...; __version=v"0.1.0")
