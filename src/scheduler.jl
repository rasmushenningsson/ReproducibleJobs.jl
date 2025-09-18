# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler
	results::Dict{ReadOnly{SpecArgs},Any}
end
Scheduler() = Scheduler(Dict{ReadOnly{SpecArgs},Any}())

let scheduler_singleton = Scheduler()
	global default_scheduler() = scheduler_singleton
end




_arg_replacer(upstream) = Base.Fix2(_arg_replacer, upstream)
_arg_replacer(x, upstream) = get(upstream, x, x) # replaces (pre)fetched specs by the value, and leaves everything else in place

_unwrap_value(upstream) = Base.Fix2(_unwrap_value, upstream)
_unwrap_value() = _unwrap_value(IdDict{Spec,Any}())

function _unwrap_value(x, upstream)
	x isa Spec && return copy_nested(_unwrap_value(), upstream[x]) # Needed to handle e.g. a result which is a vector of `ReadOnly`s
	x isa ReadOnly && return x.value
	x
end


fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep.ro) for dep in deps)



function process_dependency!(f, scheduler, dep)
	dep = f(dep)
	dep.op === Call() && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep)
end
process_dependencies!(f::F, scheduler, deps) where F =
	IdDict{Spec,Any}(dep=>process_dependency!(f, scheduler, dep) for dep in deps)
process_dependencies!(scheduler, deps) = process_dependencies!(identity, scheduler, deps)



function propagate_error(sa, vals)::Union{Nothing, ProcessingException}
	if any(x->x isa ProcessingException, vals)
		causes = filter!(x->x isa ProcessingException, collect(vals))
		return ProcessingException(sa, causes)
	else
		return nothing
	end
end


preprocess(err::ProcessingException) = err

function preprocess(sa::SpecArgs)
	f = sa.f
	try
		@info "Preprocessing $f"

		res = f(sa.args...; sa.kwargs...)
		@assert res !== nothing "Preprocessing of $f returned nothing"
		return res
	catch e
		# TODO: Do not show anything/much here, it will be shown later instead
		@warn "Error preprocessing $f"
		bt = Base.catch_backtrace()
		# Base.showerror(stdout, e, bt)
		# Base.showerror(stdout, e)
		# println()

		io = IOBuffer()
		Base.showerror(IOContext(io, :color=>true), e)
		message = String(take!(io))
		@warn message

		return ProcessingException(sa, e, stacktrace(bt))
	end
end

function replace_forwarded(sa::SpecArgs, upstream::IdDict{Spec,Any})
	err = propagate_error(sa, values(upstream))
	err !== nothing && return err

	replacer = _arg_replacer(upstream)

	args = Any[copy_nested(replacer, a) for a in sa.args]
	kwargs = Pair{Symbol,Any}[k=>copy_nested(replacer,v) for (k,v) in sa.kwargs]

	sa_forwarded = SpecArgs(sa.f, args, kwargs)
	return sa_forwarded
end


function compute(sa::SpecArgs, upstream::IdDict{Spec,Any})
	f = sa.f
	try
		@info "Running $f"
		err = propagate_error(sa, values(upstream))
		err !== nothing && return err

		v = _get_kwarg(sa, :__version, nothing)
		@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

		unwrapper = _unwrap_value(upstream)
		args = (copy_nested(unwrapper, a) for a in sa.args)
		kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in sa.kwargs if !startswith(string(k),"__"))

		res = f(args...; kwargs...)
		@assert res !== nothing "Computation of $f returned nothing"
		return res
	catch e
		# TODO: Do not show anything/much here, it will be shown later instead
		@warn "Error computing $f"
		bt = Base.catch_backtrace()
		# Base.showerror(stdout, e, bt)
		# Base.showerror(stdout, e)

		io = IOBuffer()
		Base.showerror(IOContext(io, :color=>true), e)
		message = String(take!(io))
		@warn message

		# println()
		return ProcessingException(sa, e, stacktrace(bt))
	end
end


function _fetch_and_compute!(scheduler, sa::SpecArgs, deps::Vector{Spec})
	deps = fetch_dependencies!(scheduler, deps)
	res = compute(sa, deps)
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



function _process_once!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, deps::Vector{Spec})
	sa = ro.value

	if is_preprocessing(sa)
		if !isempty(deps)
			forwarded_deps = process_dependencies!(scheduler, deps)
			sa = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
		end
		preprocessed = preprocess(sa)
		if preprocessed isa ReadOnly{SpecArgs}
			return Spec(preprocessed, nothing)
		else
			return preprocessed
		end
	end

	if !all(x->x.op === Call(), deps)
		forwarded_deps = process_dependencies!(forwarded, scheduler, deps)
		sa_forwarded = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
		sa_forwarded isa ProcessingException && return sa_forwarded
		ro_forwarded = default_deduplicator()(sa_forwarded) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		return Spec(ro_forwarded, Call())
	end

	if _get_kwarg(sa, :__use_cache)
		return cache_get!(ro) do
			_fetch_and_compute!(scheduler, sa, deps)
		end
	else
		@info "Bypassing cache"
		return _fetch_and_compute!(scheduler, sa, deps)
	end
end


# Return tuple with result and Bool telling if it's done (TODO: Make code more clear)
function process_once!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, op::T) where T
	op === nothing && return Spec(ro, nothing), true

	sa = ro.value

	# Early out, we don't need to consider dependencies for this
	if T <: Forward
		op.predicate(sa) && return (Spec(ro, nothing), true) # should op ever be set to something here?
	end


	if is_preprocessing(sa)
		# deps = get_dependencies(!isnothing, sa) # No need to collect dependencies with op===nothing since they will not be changed.
		deps = get_dependencies(op->!isnothing(op) && !(op isa Prefetch), sa) # No need to collect dependencies with op===nothing or Prefetch, since they will not be changed.
	else
		deps = get_dependencies(sa)

		# Stop if we are forwarding - but sa is ready for computation
		# I.e. ensure process_once! doesn't compute if we only ask for forwarding.
		if T <: Forward && all(s->s.op === Call(), deps)
			return (Spec(ro, Call()), true)
		end
	end

	res = get!(scheduler.results, ro) do
		_process_once!(scheduler, ro, deps)
	end

	done = !(res isa Spec)
	return res, done
end



function process!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, op::T) where T
	while true
		res, done = process_once!(scheduler, ro, op)
		done && return res
		res::Spec
		ro = res.ro
	end
end


fetch!(scheduler::Scheduler, spec::ReadOnly{SpecArgs}) = process!(scheduler, spec, Fetch())
forward!(scheduler::Scheduler, spec::ReadOnly{SpecArgs}) = process!(scheduler, spec, Forward())

function forward_once!(scheduler::Scheduler, spec::ReadOnly{SpecArgs})
	res, _ = process_once!(scheduler, spec, Forward())
	res
end


process!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec.ro, spec.op)



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
