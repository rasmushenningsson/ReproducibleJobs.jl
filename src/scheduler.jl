# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{Spec,H} # spec -> result stored on disk

	lru_capacity::Base.RefValue{Int}
	lru::LRUCache{Spec} # To prevent GC of most recently used results
end
Scheduler(cache::Cache{Spec,H}; lru_capacity=100) where H = Scheduler{H}(cache.deduplicator, cache, Ref(lru_capacity), LRUCache{Spec}())
Scheduler(deduplicator::Deduplicator{H}; lru_capacity=100, kwargs...) where H = Scheduler(Cache(Spec, deduplicator; kwargs...); lru_capacity)
Scheduler(; kwargs...) = Scheduler(Deduplicator(); kwargs...)


set_lru_capacity!(scheduler::Scheduler, capacity) = scheduler.lru_capacity[] = capacity
set_lru_capacity!(capacity) = set_lru_capacity!(get_scheduler(), capacity)

get_lru_capacity(scheduler::Scheduler) = scheduler.lru_capacity[]
get_lru_capacity() = get_lru_capacity(get_scheduler())


function evict_results!(scheduler::Scheduler; evict_all=true)
	capacity = scheduler.lru_capacity[]
	length(scheduler.lru)>capacity && @info "Evicting $(length(scheduler.lru)-capacity) result(s)."

	while !isempty(scheduler.lru) && (evict_all || length(scheduler.lru)>capacity)
		spec = lru_pop!(scheduler.lru)
		spec !== nothing && empty_result!(spec)
	end
	scheduler
end

function Base.empty!(scheduler::Scheduler)
	evict_results!(scheduler)
	force_empty!(scheduler.lru)
	# empty!(scheduler.deduplicator) # Hmm. This is problematic, because the user can still have specs, and the deduplicator shouldn't lose track of those.
	scheduler
end


fetch_dependencies!(scheduler, deps) = IdDict{SpecUnion,Any}(dep=>fetch!(scheduler, dep) for dep in deps)



function process_dependency!(scheduler, dep; parent_f)
	dep isa Call && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f, processing_errors_throw=false)
end
process_dependencies!(scheduler, deps; parent_f) =
	IdDict{SpecUnion,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)




function propagate_error(spec, vals)::Union{Nothing, ProcessingException}
	if any(x->x isa ProcessingException, vals)
		causes = filter!(x->x isa ProcessingException, collect(vals))
		return ProcessingException(spec, causes)
	else
		return nothing
	end
end


preprocess(::Scheduler, err::ProcessingException) = err

function preprocess(scheduler::Scheduler, spec::Spec)
	f = spec.f
	try
		@info "Preprocessing $f"

		res = f(spec.args...; spec.kwargs...)
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

		return ProcessingException(spec, e, stacktrace(bt))
	end
end

function replace_forwarded(spec::Spec, upstream::IdDict{<:SpecUnion,Any})
	err = propagate_error(spec, values(upstream))
	err !== nothing && return err
	return map_args(x->get(upstream,x,nothing), spec)
end


function compute(scheduler::Scheduler, spec::Spec, upstream::IdDict{<:SpecUnion,Any})
	f = spec.f
	try
		@info "Running $f"
		err = propagate_error(spec, values(upstream))
		err !== nothing && return err

		v = _get_kwarg(spec, :__version, nothing)
		@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

		sa_replaced = map_args(x->get(upstream,x,nothing), spec)
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
		return ProcessingException(spec, e, stacktrace(bt))
	end
end


function _fetch_and_compute!(scheduler, spec::Spec, deps::Vector{<:SpecUnion})
	deps = fetch_dependencies!(scheduler, deps)
	res = compute(scheduler, spec, deps)
	@assert !(res isa SpecUnion)
	res
end


function _fetch_and_compute_cached!(scheduler, spec::Spec, deps::Vector{<:SpecUnion})
	inner_spec = spec.args[1]::SpecUnion
	inner_sa = get_sa(inner_spec)
	inner_deps = get_dependencies(inner_sa)
	@assert all(s->s isa Call, inner_deps) # The outer Call has enforced all inner specs to be Calls has well.

	cache_get!(scheduler.cache, inner_sa) do
		_fetch_and_compute!(scheduler, inner_sa, inner_deps)
	end
end

# TODO: Simplify code
function _fetch_and_compute_sub!(scheduler, spec::Spec, deps::Vector{<:SpecUnion})
	@assert spec.f in (compoundresult_sub, compoundresult_keys)

	cached_spec = get_sa(spec.args[1]::SpecUnion)
	@assert cached_spec.f == get_cached
	cached_deps = get_dependencies(cached_spec)
	@assert all(s->s isa Call, cached_deps) # The outer Call has enforced all sub specs to be Calls has well.

	# Try in this order
	# 0. (Already done) Is it cached and still valid in spec.result.
	# 1. Is the cached_spec result still valid? Then return subresult from that.
	# 2. Can we reconstruct from the cached_spec weak_result?
	# 3. Is the cached_spec cached to disk? Then load the subresult (only) from disk.
	# 4. Compute compoundresult and return sub.

	if spec.f == compoundresult_sub
		sub = spec.args[2]::String
	else #if spec.f == compoundresult_keys
		sub = nothing
	end


	# TODO: Put part of this in a helper function, get_result?, in spec.jl?
	# 1.
	if cached_spec.result !== NotValid()
		@info "Found cached CompoundResult ($(get_sa(cached_spec.args[1]).f))"
		cr = cached_spec.result
		cr isa Exception && return cr
		@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
		return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
	end

	w = cached_spec.weak_result
	if w !== NotValid()
		@info "Attempting 2 ($(get_sa(cached_spec.args[1]).f))"

		# Attempt to reconstruct from weakly stored CompoundResult
		@assert w isa CompoundResult "Expected CompoundResult, got $(typeof(w))."
		# sub === nothing && return get_keys(w)
		sub === nothing && return (@info "2 success $sub ($(get_sa(cached_spec.args[1]).f))"; return get_keys(w))
		v = reconstruct_weak_rec(get_subresult(w, sub))
		# v !== NotValid() && return v
		v !== NotValid() && (@info "2 success $sub ($(get_sa(cached_spec.args[1]).f))"; return v)
		@info "2 failed ($(get_sa(cached_spec.args[1]).f))"
	end

	# 3.
	inner_spec = get_sa(cached_spec.args[1])
	@info "Attempting 3 ($(get_sa(cached_spec.args[1]).f))"
	v = cache_try_get_compoundresult(scheduler.cache, inner_spec; sub, return_keys=sub===nothing)
	# v !== NotValid() && return v
	v !== NotValid() && (@info "3 success $sub ($(get_sa(cached_spec.args[1]).f))"; return v)
	@info "3 failed ($(get_sa(cached_spec.args[1]).f))"

	# 4.
	@info "Attempting 4 ($(get_sa(cached_spec.args[1]).f))"
	cr = get_result!(cached_spec) do # This is to ensure cached_spec.result gets set, maybe use set_result! instead? Because we should never reach here if cached_spec.result !== nothing.
		_fetch_and_compute_cached!(scheduler, cached_spec, cached_deps)
	end
	cr isa Exception && return cr
	cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))

	lru_touch!(scheduler.lru, inner_spec)

	return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
end



function _process_once!(scheduler::Scheduler, spec::Spec, deps::Vector{<:SpecUnion})
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=spec.f)

	if !isempty(forwarded_deps)
		spec = replace_forwarded(spec, forwarded_deps)::Union{Spec,ProcessingException}
	end

	if is_preprocessing(spec)
		preprocess(scheduler, spec)
	else
		spec isa ProcessingException && return spec

		spec = deduplicate!(scheduler.deduplicator, spec)
		Call(spec)
	end
end





# TODO: Move these somewhere else?
# These functions are actually never called. We just use them as singleton values to show that something is using the on-disk cache.
function compoundresult_sub end
function compoundresult_keys end
function get_cached end

function cached(spec, sub::Union{Nothing,String}=nothing; return_keys::Bool=false)
	@assert sub==nothing || return_keys==false

	c = create_spec(get_cached, spec; __version=v"1.0.0")
	if sub !== nothing
		create_spec(compoundresult_sub, c, sub; __version=v"0.0.1")
	elseif return_keys
		create_spec(compoundresult_keys, c; __version=v"0.0.1")
	else
		c
	end
end


# # TODO: Move these somewhere else?
# function get_cached end # `get_cached` is actually never called. We just use it as singleton value to show that something is using the on-disk cache.

# # Use `sub` to retrieve parts of `CompoundResult`s
# function cached(spec, sub::String...; return_keys=false)
# 	extra_kwargs = (return_keys ? (; return_keys) : (;)) # only pass kwarg if set to true
# 	create_spec(get_cached, spec, sub...; extra_kwargs..., __version=v"1.0.0")
# end



# DEBUG
let proccessing_counts = Dict{Hash,Int}()
	global function processing_count(h::Hash)
		c = get(proccessing_counts, h, 0) + 1
		proccessing_counts[h] = c
		c
	end
end



# Return tuple with result and Bool telling if it's done (TODO: Make code more clear)
function process_once!(scheduler::Scheduler, s::T; parent_f) where T<:SpecUnion
	# Early out, we don't need to consider dependencies for this
	if parent_f !== nothing && T <: Union{Spec,Prefetch}
		if !should_forward_child(parent_f, s.f)
			return s, true
		end
	end

	spec = get_sa(s)

	deps = get_dependencies(spec)

	if !is_preprocessing(spec) && all(x->x isa Call, deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		T===Spec && return (Call(spec), true)


		res = get_result!(spec) do
			# # DEBUG
			# h = lookup_hash(scheduler.deduplicator, spec)
			# @info "Computing $(spec.f) ($(hash_string(h)[1:6]), n=$(processing_count(h)))"


			if spec.f == compoundresult_sub || spec.f == compoundresult_keys
				_fetch_and_compute_sub!(scheduler, spec, deps)
			elseif spec.f == get_cached
				_fetch_and_compute_cached!(scheduler, spec, deps)
			else
				_fetch_and_compute!(scheduler, spec, deps)
			end
		end
		@assert !(res isa CompoundResult) # Is this a good place to check? Maybe should be ensured earlier.
		@assert !(res isa SpecUnion)

		lru_touch!(scheduler.lru, spec)

		return res, true
	end

	res = get_next!(spec) do
		# # DEBUG
		# h = lookup_hash(scheduler.deduplicator, spec)
		# @info "Preprocessing $(spec.f) ($(hash_string(h)[1:6]), n=$(processing_count(h)))"

		_process_once!(scheduler, spec, deps)
	end

	if res isa SpecUnion
		return res, false
	else
		return res, true # forwarding returned a value, we are done
	end
end


function process!(scheduler::Scheduler, s::T; parent_f=nothing, processing_errors_throw=true) where T<:SpecUnion
	evict_results!(scheduler; evict_all=false)

	while true
		res, done = process_once!(scheduler, s; parent_f)
		# done && return res
		if done
			processing_errors_throw && res isa Exception && throw(res)
			return res
		end
		res::SpecUnion
		s = transfer_op(s, res)
	end
end


fetch!(scheduler::Scheduler, s::SpecUnion; kwargs...) = process!(scheduler, fetched(s); kwargs...)
forward!(scheduler::Scheduler, s::SpecUnion; kwargs...) = process!(scheduler, get_sa(s); kwargs...) # strip Wrapper to get forwarding

function forward_once!(scheduler::Scheduler, s::SpecUnion; parent_f=nothing, processing_errors_throw=true)
	res, _ = process_once!(scheduler, get_sa(s); parent_f) # strip Wrapper to get forwarding
	processing_errors_throw && res isa Exception && throw(res)
	res
end


fetch!(s::SpecUnion; kwargs...) = fetch!(get_scheduler(), s; kwargs...)
forward!(s::SpecUnion; kwargs...) = forward!(get_scheduler(), s; kwargs...)
forward_once!(s::SpecUnion; kwargs...) = forward_once!(get_scheduler(), s; kwargs...)
process!(s::SpecUnion; kwargs...) = process!(get_scheduler(), s; kwargs...)



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
