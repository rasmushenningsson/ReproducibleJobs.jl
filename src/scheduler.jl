# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler
	jobs::IdDict{Spec,JobData}
end

let scheduler_singleton = Scheduler()
	global default_scheduler() = scheduler_singleton
end
