struct NotComputed end

mutable struct Job
	const spec::Spec
	result::Any
end
Job(spec::Spec) = Job(spec, NotComputed())


preprocess_standard(job::Job) = job.spec



fetch!(job; scheduler=default_scheduler(), kwargs...) =
	job.result = fetch!(scheduler, job.spec; kwargs...)

# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", job::Job)
	println(io, "Job Spec:")
	show(io, MIME"text/plain"(), job.spec)
	# println(io)

	# TODO: Show better status (also follow forwarding in the Scheduler). Something like:
	# * Not computed
	# * Cached on disk
	# * Waiting for dependencies
	# * Queued
	# * Being computed
	# * Done
	# * Errored
	print(io, "Job Status: ", job.result === NotComputed() ? "Not fetched" : "Done")
	if job.result !== NotComputed()
		let io = IOContext(io, :compact=>true)
			println(io)
			print(io, "Job Result: ")
			show(io, job.result)
		end
	end
end

# _unwrap_job(x) = x isa Job ? x.spec : x

# function create_job(args...; deduplicator=default_deduplicator(), use_cache=true, kwargs...)
# 	args = _unwrap_job.(args)
# 	kwargs = [k=>_unwrap_job(v) for (k,v) in kwargs]
# 	Job(create_spec(args, kwargs; deduplicator, use_cache))
# end
