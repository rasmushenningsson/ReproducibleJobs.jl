struct NotComputed end

mutable struct Job
	const spec::Spec
	result::Any
end
Job(spec::Spec) = Job(spec, NotComputed())

function fetch!(job; scheduler=default_scheduler())
	job.result = fetch!(scheduler, job.spec)
end

# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", job::Job)
	println(io, "Job Spec:")
	show(io, MIME"text/plain"(), job.spec)
	# println(io)
	print(io, "Job Result: ")
	let io = IOContext(io, :compact=>true)
		if job.result === NotComputed()
			print(io, cache_haskey(job.spec) ? "Cached on disk" : "Not computed")
		else
			show(io, job.result)
		end

	end
end
