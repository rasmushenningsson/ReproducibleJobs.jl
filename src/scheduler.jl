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


# # Maps spec and dependencies to f, args, kwargs so function can be called
# function compute(spec::Spec, upstream::IdDict{Spec,Any})
# 	vf = get_versioned_function(spec)
# 	sa = _get_spec_args(spec)

# 	unwrapper = _unwrap_value(upstream)
# 	args = (copy_nested(unwrapper, a) for a in sa.args)
# 	kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in sa.kwargs if !startswith(string(k),"__"))

# 	@info "Running $vf"
# 	vf.f(args...; kwargs...)
# end

# function fetch_dependencies!(scheduler, spec)
# 	# Fetch dependencies
# 	upstream = IdDict{Spec,Any}()
# 	visit_dependencies(spec) do dep
# 		upstream[dep] = fetch!(scheduler, dep) # always forward in here
# 	end
# 	upstream
# end

# fetch_dependencies!(scheduler, deps) = deps .=> fetch!.(scheduler, deps)
fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep) for dep in deps)


function compute(spec::Spec, upstream::IdDict{Spec,Any})
	vf = get_versioned_function(spec)
	sa = _get_spec_args(spec)

	unwrapper = _unwrap_value(upstream)
	args = (copy_nested(unwrapper, a) for a in sa.args)
	kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in sa.kwargs if !startswith(string(k),"__"))

	@info "Running $vf"
	res = vf.f(args...; kwargs...)
	@assert res !== nothing "Computation of $spec returned nothing"
	res
end



function _fetch_and_compute!(scheduler, spec)
	deps = get_dependencies(spec)::Vector{Spec}
	deps = fetch_dependencies!(scheduler, deps)
	compute(spec, deps)
end


function _process!(scheduler::Scheduler, spec::Spec)
	# Possibilities:
	# 1. We need to preprocess: possibly fetch and then compute(spec, fetched)
	# 2. We need to forward subspecs and replace subspecs with forwarded subspecs
	# 3. We need to prefetch and replace prefetched specs with results
	# 4. We need to fetch and compute (and cache if needed)

	# TODO: avoid code repetions below

	if is_preprocessing(spec)
		deps = get_dependencies(spec)::Vector{Spec}
		deps = fetch_dependencies!(scheduler, deps)
		res = compute(spec, deps)
	elseif !spec.fully_forwarded
		# find all dependencies (including those marked for prefetch (how about specs marked as other things?))
		# fully forward each dependency
		# replace dependencies with fully forwarded

		# DUMMY IMPLEMENTATION
		return Spec(spec.ro, spec.use_cache, true)
	elseif false # should_prefetch(spec)
		# find all dependencies that should be prefetched
		# fetch dependencies
		# replace dependencies with fetched results
	else
		if spec.use_cache
			cache_get!(spec) do
				_fetch_and_compute!(scheduler, spec)
			end
		else
			@info "Bypassing cache"
			_fetch_and_compute!(scheduler, spec)
		end
	end


	# result = get!(scheduler.results, spec) do
	# 	# If it's in the cache, we don't need to fetch! upstream jobs
	# 	if spec.use_cache
	# 		res = cache_get(spec, nothing)
	# 		if res !== nothing
	# 			if res isa Spec
	# 				# Since the Spec was loaded from file, it has not been deduplicated in this session, so we need to do that here.
	# 				res = default_deduplicator()(res) # TODO: avoid using default_deduplicator() here - get from scheduler somehow
	# 			end
	# 			return res
	# 		end
	# 	end

	# 	# Not found in cache





	# 	# @show is_preprocessing(spec)

	# 	deps = get_dependencies(spec)::Vector{Spec}
	# 	deps = fetch_dependencies!(scheduler, deps)

	# 	res = compute(spec, deps)

	# 	if spec.use_cache
	# 		cache_insert!(spec, res) # No need to check cache here, that was done above.
	# 	else
	# 		@info "Bypassing cache"
	# 	end

	# 	return res
	# end

end

function process!(scheduler::Scheduler, spec::Spec, mode::Symbol)
	@assert mode in (:forward_once,:forward,:compute)

	while true
		if spec.fully_forwarded && mode in (:forward_once, :forward)
			return spec
		end

		# res = _process!(scheduler, spec)
		res = get!(scheduler.results, spec) do
			_process!(scheduler, spec)
		end


		res isa Spec || return res
		spec = res::Spec

		mode == :forward_once && return spec
	end
end


fetch!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec, :compute)
forward!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec, :forward)
forward_once!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec, :forward_once)


# function fetch!(scheduler::Scheduler, spec::Spec; forward=true)
# 	result = get!(scheduler.results, spec) do
# 		# If it's in the cache, we don't need to fetch! upstream jobs
# 		res = nothing
# 		if spec.use_cache
# 			res = cache_get(spec, nothing)

# 			# Since the Spec was loaded from file, it has not been deduplicated in this session, so we need to do that here.
# 			if res isa Spec
# 				res = default_deduplicator()(res) # TODO: avoid using default_deduplicator() here - get from scheduler somehow
# 			end
# 		end

# 		if res === nothing # Not found in cache
# 			# @show is_preprocessing(spec)


# 			deps = get_dependencies(spec)::Vector{Spec}
# 			deps = fetch_dependencies!(scheduler, deps)

# 			res = compute(spec, deps)

# 			if spec.use_cache
# 				cache_insert!(spec, res) # No need to check cache here, that was done above.
# 			else
# 				@info "Bypassing cache"
# 			end


# 			# preprocess_fun = _get_kwarg(spec, :__preprocess_spec, nothing)

# 			# if preprocess_fun !== nothing
# 			# 	# Preprocess without fetching dependencies
# 			# 	res = (preprocess_fun::VersionedFunction).f(spec)
# 			# else
# 			# 	upstream = fetch_dependencies!(scheduler, spec)
# 			# 	res = compute(spec, upstream)
# 			# end

# 			# if spec.use_cache
# 			# 	cache_insert!(spec, res) # No need to check cache here, that was done above.
# 			# else
# 			# 	@info "Bypassing cache"
# 			# end
# 		end
# 		res
# 	end

# 	if forward && result isa Spec
# 		result = fetch!(scheduler, result; forward)
# 	end
# 	result
# end


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
