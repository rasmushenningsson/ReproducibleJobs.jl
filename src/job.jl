struct NotComputed end

mutable struct Job
	const spec::Spec
	result::Any
end
Job(spec::Spec) = Job(spec, NotComputed())


process_arg(job::Job) = job.spec
_prefetch(job::Job) = _prefetch(job.spec)



fetch!(job::Job; scheduler=default_scheduler()) =
	job.result = fetch!(scheduler, job.spec)

function forward!(job::Job; scheduler=default_scheduler())
	spec = forward!(scheduler, job.spec)
	spec === job.spec ? job : Job(spec)
end
function forward_once!(job::Job; scheduler=default_scheduler())
	spec = forward_once!(scheduler, job.spec)
	spec === job.spec ? job : Job(spec)
end


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
