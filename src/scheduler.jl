# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{SpecArgs,H} # spec -> forwarded spec or result
end
Scheduler(cache::Cache{SpecArgs,H}) where H = Scheduler{H}(cache.deduplicator, cache)
Scheduler(deduplicator::Deduplicator{H}; kwargs...) where H = Scheduler(Cache(SpecArgs, deduplicator; kwargs...))
# Scheduler() = Scheduler(default_deduplicator())
Scheduler(; kwargs...) = Scheduler(Deduplicator(); kwargs...)


function Base.empty!(scheduler::Scheduler)
	empty!(scheduler.deduplicator)
	empty!(scheduler.cache)
	scheduler
end



fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep) for dep in deps)



function process_dependency!(scheduler, dep; parent_f)
	dep.op === Call() && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f)
end
process_dependencies!(scheduler, deps; parent_f) =
	IdDict{Spec,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)




function propagate_error(sa, vals)::Union{Nothing, ProcessingException}
	if any(x->x isa ProcessingException, vals)
		causes = filter!(x->x isa ProcessingException, collect(vals))
		return ProcessingException(sa, causes)
	else
		return nothing
	end
end


preprocess(::Scheduler, err::ProcessingException) = err

function preprocess(scheduler::Scheduler, sa::SpecArgs)
	f = sa.f
	try
		@info "Preprocessing $f"

		res = f(sa.args...; sa.kwargs...)
		@assert res !== nothing "Preprocessing of $f returned nothing"

		res = deduplicate!(scheduler.deduplicator, res) # needed because forwarding can return a value

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
	return map_specs(x->get(upstream,x,nothing), sa)
end


function compute(scheduler::Scheduler, sa::SpecArgs, upstream::IdDict{Spec,Any})
	f = sa.f
	try
		@info "Running $f"
		err = propagate_error(sa, values(upstream))
		err !== nothing && return err

		v = _get_kwarg(sa, :__version, nothing)
		@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

		sa_replaced = map_specs(x->get(upstream,x,nothing), sa)
		args = sa_replaced.args
		kwargs = sa_replaced.kwargs

		# Get rid of kwargs where the key starts with __
		kwargs = NamedTuple{filter(k->!startswith(string(k),"__"), keys(kwargs))}(kwargs)

		res = f(args...; kwargs...)
		@assert res !== nothing "Computation of $f returned nothing"

		res = deduplicate!(scheduler.deduplicator, res)

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
	res = compute(scheduler, sa, deps)
	@assert !(res isa Spec)
	res
end


function _process_once!(scheduler::Scheduler, sa::SpecArgs, deps::Vector{Spec})
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sa.f)
	if !isempty(forwarded_deps)
		sa = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
	end

	if is_preprocessing(sa)
		preprocess(scheduler, sa)
	else
		sa isa ProcessingException && return sa

		sa = deduplicate!(scheduler.deduplicator, sa)
		Spec(sa, Call())
	end
end






# TODO: Move these somewhere else?
function get_cached end # `get_cached` is actually never called. We just use it as singleton value to show that something is using the on-disk cache.

# Use `sub` to retrieve parts of `CompoundResult`s
function cached(spec, sub::String...; return_keys=false)
	extra_kwargs = (return_keys ? (; return_keys) : (;)) # only pass kwarg if set to true
	create_spec(get_cached, spec, sub...; extra_kwargs..., __version=v"1.0.0")
end




# Return tuple with result and Bool telling if it's done (TODO: Make code more clear)
function process_once!(scheduler::Scheduler, sa::SpecArgs, op::T; parent_f) where T
	# Early out, we don't need to consider dependencies for this
	if parent_f !== nothing && T <: Union{Forward,Prefetch}
		if !should_forward_child(parent_f, sa.f)
			return Spec(sa, op), true # Keep Forward/Prefetch op
		end
	end

	deps = get_dependencies(sa)

	if !is_preprocessing(sa) && all(s->s.op === Call(), deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		T <: Forward && return (Spec(sa, Call()), true)

		if sa.f === get_cached
			inner_spec = sa.args[1]::Spec
			inner_sa = inner_spec.sa
			@assert inner_sa.f !== get_cached # we cannot handle nested get_cached
			inner_deps = get_dependencies(inner_sa)
			@assert all(s->s.op === Call(), inner_deps) # The outer Call has enforced all inner `op`s to be called has well.

			# The remaining args specify subresults of `CompoundResult`s
			sub = length(sa.args)==1 ? nothing : only(sa.args[2:end]) # we only support one level atm
			return_keys = _get_kwarg(sa, :return_keys, false)

			# TODO: Cleanup and simplify code
			if sub !== nothing || return_keys
				res = cache_get_subresult!(scheduler.cache, inner_sa; use_disk=true, sub, return_keys) do
					_fetch_and_compute!(scheduler, inner_sa, inner_deps)
				end
			else
				res = cache_get!(scheduler.cache, inner_sa; use_disk=true) do
					_fetch_and_compute!(scheduler, inner_sa, inner_deps)
				end
			end
		else
			res = cache_get!(scheduler.cache, sa; use_disk=false) do
				_fetch_and_compute!(scheduler, sa, deps)
			end
		end

		@assert !(res isa Spec)
		return res, true
	end

	res = cache_get!(scheduler.cache, sa; use_disk=false) do
		_process_once!(scheduler, sa, deps) # Should we add op back in?
	end

	if res isa Spec
		return res, false
	else
		return res, true # forwarding returned a value, we are done
	end
end


function process!(scheduler::Scheduler, sa::SpecArgs, op::T; parent_f=nothing) where T
	while true
		res, done = process_once!(scheduler, sa, op; parent_f)
		done && return res
		res::Spec
		sa = res.sa
	end
end


fetch!(scheduler::Scheduler, spec::Spec; kwargs...) = process!(scheduler, spec.sa, Fetch(); kwargs...)
forward!(scheduler::Scheduler, spec::Spec; kwargs...) = process!(scheduler, spec.sa, Forward(); kwargs...)

function forward_once!(scheduler::Scheduler, spec::Spec; parent_f=nothing)
	res, _ = process_once!(scheduler, spec.sa, Forward(); parent_f)
	res
end

process!(scheduler::Scheduler, spec::Spec; kwargs...) = process!(scheduler, spec.sa, spec.op; kwargs...)



# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	# println("Results: ")
	# compact_io = IOContext(io, :compact=>true)
	# for (k,v) in scheduler.cache
	# 	show(compact_io, k)
	# 	print(compact_io, " => ")
	# 	show(compact_io, v)
	# 	println(io)
	# end
	print(io,')')
end
