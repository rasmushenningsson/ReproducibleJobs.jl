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


_unwrap_value(upstream) = Base.Fix2(_unwrap_value, upstream)
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

	unwrapper = _unwrap_value(upstream)
	args = (copy_nested(unwrapper, a) for a in ispec.args)
	kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in ispec.kwargs if !startswith(string(k),"__"))

	@info "Running $vf"
	vf.f(args...; kwargs...)
end

function fetch_dependencies!(scheduler, spec)
	# Fetch dependencies
	upstream = IdDict{Spec,Any}()
	visit_dependencies(spec) do dep
		upstream[dep] = fetch!(scheduler, dep) # always forward in here
	end
	upstream
end


function fetch!(scheduler::Scheduler, spec::Spec; forward=true)
	result = get!(scheduler.results, spec) do
		# If it's in the cache, we don't need to fetch! upstream jobs
		res = nothing
		if spec.use_cache
			res = cache_get(spec, nothing)

			# Since the Spec was loaded from file, it has not been deduplicated in this session, so we need to do that here.
			if res isa Spec
				res = default_deduplicator()(res) # TODO: avoid using default_deduplicator() here - get from scheduler somehow
			end
		end

		if res === nothing # Not found in cache
			preprocess_fun = _get_kwarg(spec, :__preprocess_spec, nothing)

			if preprocess_fun !== nothing
				# Preprocess without fetching dependencies
				res = (preprocess_fun::VersionedFunction).f(spec)
			else
				upstream = fetch_dependencies!(scheduler, spec)
				res = compute(spec, upstream)
			end

			if spec.use_cache
				cache_insert!(spec, res) # No need to check cache here, that was done above.
			else
				@info "Bypassing cache"
			end
		end
		res
	end

	if forward && result isa Spec
		result = fetch!(scheduler, result; forward)
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
