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



_arg_replacer(upstream) = Base.Fix1(_arg_replacer, upstream)
_arg_replacer(upstream, x) = get(upstream, x, x) # replaces prefetched specs by the value, and leaves everything else in place


function get_prefetch_dependencies(spec)
	deps = Spec[]
	visit_dependencies(spec) do x
		# TODO: ensure that the __fetched flag is no longer set
		any(isequal(:__fetched=>true), _get_spec_args(x).kwargs) && push!(deps, x)
	end
	deps
end



_unwrap_value(upstream) = Base.Fix2(_unwrap_value, upstream)
function _unwrap_value(x, upstream)
	# Manual dispatch since we have few types
	x isa Spec && return upstream[x]
	x isa ReadOnly && return x.value
	x
end

fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep) for dep in deps)
forward_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>forward!(scheduler, dep) for dep in deps)


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
		return res = compute(spec, deps)
	end

	if !spec.fully_forwarded
		# find all dependencies (including those marked for prefetch (how about specs marked as other things?))
		# fully forward each dependency
		# replace dependencies with fully forwarded

		forwarded_deps = get_dependencies(spec)::Vector{Spec}
		forwarded_deps = forward_dependencies!(scheduler, forwarded_deps)

		replacer = _arg_replacer(forwarded_deps)

		sa = spec.ro.value
		args = Any[copy_nested(replacer, a) for a in sa.args]
		kwargs = Pair{Symbol,Any}[k=>copy_nested(replacer,v) for (k,v) in sa.kwargs]

		sa_forwarded = SpecArgs(args, kwargs)
		sa_forwarded = default_deduplicator()(sa_forwarded) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		return Spec(sa_forwarded, spec.use_cache, true)
	end

	prefetch_deps = get_prefetch_dependencies(spec)
	if !isempty(prefetch_deps)
		prefetch_deps = fetch_dependencies!(scheduler, prefetch_deps)

		replacer = _arg_replacer(prefetch_deps)

		sa = spec.ro.value
		args = Any[copy_nested(replacer, a) for a in sa.args]
		kwargs = Pair{Symbol,Any}[k=>copy_nested(replacer,v) for (k,v) in sa.kwargs if !startswith(string(k),"__")]

		sa_prefetched = SpecArgs(args, kwargs)
		sa_prefetched = default_deduplicator()(sa_prefetched) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		return Spec(sa_prefetched, spec.use_cache, spec.fully_forwarded)
	end

	if spec.use_cache
		return cache_get!(spec) do
			_fetch_and_compute!(scheduler, spec)
		end
	else
		@info "Bypassing cache"
		return _fetch_and_compute!(scheduler, spec)
	end
end

function process!(scheduler::Scheduler, spec::Spec, mode::Symbol)
	@assert mode in (:forward_once,:forward,:compute)

	while true
		if spec.fully_forwarded && mode in (:forward_once, :forward)
			return spec
		end

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
