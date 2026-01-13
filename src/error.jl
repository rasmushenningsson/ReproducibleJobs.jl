error_spec(args...) = create_spec(error, args...; __version=v"0.1.0")
error_job(args...) = Job(error_spec(args...))
