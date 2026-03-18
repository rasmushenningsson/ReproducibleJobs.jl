struct NotComputed end

mutable struct Job
	const spec::Spec
	result::Any

	function Job(spec::Spec, result)
		new(Spec(spec.sa, Fetch()), result) # The only valid op is Fetch.
	end
end
Job(spec::Spec) = Job(spec, NotComputed())

Base.Broadcast.broadcastable(job::Job) = Ref(job) # treat as scalar for broadcasting

deduplicate_type(::Type{Job}) = true
deduplication_preprocess(job::Job) = Spec(job.spec.sa) # Resets the op to default


fetched(job::Job) = fetched(job.spec)
prefetched(job::Job) = prefetched(job.spec)



function fetch!(job::Job; scheduler=get_scheduler())
	if job.result === NotComputed()
		job.result = process!(scheduler, job.spec)
	end
	job.result isa ProcessingException && throw(job.result)
	job.result
end

function forward(job::Job; scheduler=get_scheduler())
	res = forward!(scheduler, job.spec)
	res isa ProcessingException && throw(res)
	res === job.spec ? job : Job(res)
end
function forward_once(job::Job; scheduler=get_scheduler())
	res = forward_once!(scheduler, job.spec)
	res isa ProcessingException && throw(res)
	res === job.spec ? job : Job(res)
end


# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", job::Job)
	println(io, "Job Spec:")
	show(io, MIME"text/plain"(), job.spec)
	println(io)

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
