struct NotComputed end

mutable struct Job
	#const spec::ReadOnly{SpecArgs} # Rename to ro?
	const spec::Spec
	result::Any

	function Job(spec::Spec, result)
		new(Spec(spec.ro, Fetch()), result) # The only valid op is Fetch.
	end
end
# Job(ro::ReadOnly{SpecArgs}) = Job(ro, NotComputed())
Job(spec::Spec) = Job(spec, NotComputed())

Base.Broadcast.broadcastable(job::Job) = Ref(job) # treat as scalar for broadcasting

_to_spec(job::Job) = Spec(job.spec.ro) # Resets the op to default

# copy_arg(job::Job) = Spec(job.spec) # Already managed, just wrap in a Spec
copy_arg(job::Job) = _to_spec(job) # Already managed, just return Spec

_fetched(job::Job) = _fetched(_to_spec(job))
_prefetched(job::Job) = _prefetched(_to_spec(job))

forwarded(job::Job) = forwarded(_to_spec(job))
forwarded(predicate, job::Job) = forwarded(predicate, _to_spec(job))



function fetch!(job::Job; scheduler=default_scheduler(), managed=false)
	if job.result === NotComputed()
		# job.result = manage(fetch!(scheduler, job.spec.ro))
		job.result = manage(process!(scheduler, job.spec))
	end
	job.result isa ProcessingException && throw(job.result)
	managed ? job.result : unmanage(job.result)
end

function forward(job::Job; scheduler=default_scheduler())
	res = forward!(scheduler, job.spec)
	res isa ProcessingException && throw(res)
	res === job.spec ? job : Job(res)
end
function forward_once(job::Job; scheduler=default_scheduler())
	res = forward_once!(scheduler, job.spec)
	res isa ProcessingException && throw(res)
	res === job.spec ? job : Job(res)
end


# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", job::Job)
	println(io, "Job Spec:")
	show(io, MIME"text/plain"(), job.spec)
	# show(io, MIME"text/plain"(), Spec(job.spec)) # A little workaround until I refactor printing to work with ReadOnly{SpecArgs} directly
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
