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




_arg_replacer(upstream) = Base.Fix2(_arg_replacer, upstream)
_arg_replacer(x, upstream) = get(upstream, x, x) # replaces prefetched specs by the value, and leaves everything else in place

_unwrap_value(upstream) = Base.Fix2(_unwrap_value, upstream)
_unwrap_value() = _unwrap_value(IdDict{Spec,Any}())

function _unwrap_value(x, upstream)
	x isa Spec && return copy_nested(_unwrap_value(), upstream[x]) # Needed to handle e.g. a result which is a vector of `ReadOnly`s
	x isa ReadOnly && return x.value
	x
end


fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler,dep) for dep in deps)

# TODO: find a better name?
forward_prefetch_dependencies!(scheduler, deps) =
	IdDict{Spec,Any}(dep=>process!(scheduler, dep, dep.prefetch ? :compute : :forward) for dep in deps)



function preprocess(spec::Spec, upstream::IdDict{Spec,Any})
	f = spec.f

	@info "Preprocessing $f"
	res = f(spec, upstream)
	@assert res !== nothing "Preprocessing of $f returned nothing"
	res
end


function compute(spec::Spec, upstream::IdDict{Spec,Any})
	f = spec.f

	v = get(spec.kwargs, :__version, nothing)
	@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

	sa = _get_spec_args(spec)
	unwrapper = _unwrap_value(upstream)
	args = (copy_nested(unwrapper, a) for a in sa.args)
	kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in sa.kwargs if !startswith(string(k),"__"))

	@info "Running $f"
	res = f(args...; kwargs...)
	@assert res !== nothing "Computation of $f returned nothing"
	res
end


function _fetch_and_compute!(scheduler, spec)
	deps = get_dependencies(spec)::Vector{Spec}
	deps = fetch_dependencies!(scheduler, deps)
	res = compute(spec, deps)
	@assert !(res isa Spec)

	# By returning a Managed result, the computing function takes responsibility of the contents, otherwise we need to standardize
	if res isa Managed
		res = res.x
	else
		f = deduplicate_leaves(default_deduplicator()) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		res = copy_nested(f, res)
	end

	res
end


function _process!(scheduler::Scheduler, spec::Spec)
	# Possibilities:
	# 1. We need to preprocess: possibly fetch and then compute(spec, fetched)
	# 2. We need to forward/prefetch subspecs and replace subspecs with forwarded/prefetched subspecs
	# 3. We need to fetch and compute (and cache if needed)

	# TODO: avoid code repetions below

	if is_preprocessing(spec)
		deps = get_dependencies(spec)::Vector{Spec}
		deps = fetch_dependencies!(scheduler, deps)
		return preprocess(spec, deps)::Spec
	end

	if !spec.forwarding_complete
		forwarded_deps = get_dependencies(spec)::Vector{Spec}
		forwarded_deps = forward_prefetch_dependencies!(scheduler, forwarded_deps)
		replacer = _arg_replacer(forwarded_deps)

		sa = spec.ro.value
		args = Any[copy_nested(replacer, a) for a in sa.args]
		kwargs = Pair{Symbol,Any}[k=>copy_nested(replacer,v) for (k,v) in sa.kwargs]

		# sa_forwarded = SpecArgs(args, kwargs)
		sa_forwarded = SpecArgs(sa.f, args, kwargs)
		sa_forwarded = default_deduplicator()(sa_forwarded) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		return Spec(sa_forwarded, spec.use_cache, true, spec.prefetch)
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
		if spec.forwarding_complete && mode in (:forward_once, :forward)
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
