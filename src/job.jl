struct NotComputed end

mutable struct Job
	const spec::Spec
	result::Any
end
Job(spec::Spec) = Job(spec, NotComputed())

Base.Broadcast.broadcastable(job::Job) = Ref(job) # treat as scalar for broadcasting

copy_arg(job::Job) = job.spec # Already managed, just unwrap
_prefetch(job::Job) = _prefetch(job.spec)



function fetch!(job::Job; scheduler=default_scheduler(), managed=false)
	if job.result === NotComputed()
		job.result = Managed(fetch!(scheduler, job.spec))
	end
	managed ? job.result : unmanage(job.result)
end

function forward(job::Job; scheduler=default_scheduler())
	spec = forward!(scheduler, job.spec)
	spec === job.spec ? job : Job(spec)
end
function forward_once(job::Job; scheduler=default_scheduler())
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
			show(io, unsafe_unmanage(job.result))
		end
	end
end
