# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler
	results::IdDict{Spec,Any}
end
Scheduler() = Scheduler(IdDict{Spec,Any}())

let scheduler_singleton = Scheduler()
	global default_scheduler() = scheduler_singleton
end


function _unwrap_value(x, upstream)
	# Manual dispatch since we have few types
	x isa Spec && return upstream[x]
	x isa ReadOnly && return x.value
	x
end


# Maps spec and dependencies to f, args, kwargs so function can be called
function compute(spec::Spec, upstream::IdDict{Spec,Any})
	vf = get_versioned_function(spec)
	ispec = _get_internal_spec(spec)

	args = [_unwrap_value(a,upstream) for a in ispec.args]
	kwargs = [k=>_unwrap_value(v,upstream) for (k,v) in ispec.kwargs if k != :versionedfunction]

	@info "Running $vf"
	vf.f(args...; kwargs...)
end


function fetch!(scheduler::Scheduler, spec::Spec; forward=true)
	result = get!(scheduler.results, spec) do
		# If it's in the cache, we don't need to fetch! upstream jobs
		res = nothing
		if spec.use_cache
			res = cache_get(spec, nothing)
		end

		if res === nothing # Not found in cache
			# first process dependencies
			upstream = IdDict{Spec,Any}()
			visit_dependencies(spec) do dep
				upstream[dep] = fetch!(scheduler, dep) # always forward in here
			end

			if spec.use_cache
				res = cache_get!(spec) do
					compute(spec, upstream)
				end
			else
				@info "Bypassing cache"
				res = compute(spec, upstream)
			end
		end
		res
	end

	if result isa Spec
		# NB: We must deduplicate a Spec if it was loaded from file
		result = deduplicate!(default_deduplicator(), result) # TODO: avoid using default_deduplicator() here - get from scheduler somehow
		if forward
			result = fetch!(scheduler, result; forward)
		end
	end
	result
end


# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	println("Results: ")
	compact_io = IOContext(io, :compact=>true)
	for (k,v) in scheduler.results
		show(compact_io, k)
		print(compact_io, " => ")
		show(compact_io, v)
		println(io)
	end
	print(io,')')
end
