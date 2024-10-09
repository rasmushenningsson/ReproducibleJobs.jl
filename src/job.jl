mutable struct Job
	const spec::Spec
	# TODO: maybe status and value, or maybe the handle is used for that.
end

fetch!(job; scheduler=default_scheduler()) = fetch!(scheduler, job.spec)
