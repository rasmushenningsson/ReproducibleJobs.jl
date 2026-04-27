# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{SpecArgs,H} # sa -> result stored on disk

	lru_item_capacity::Base.RefValue{Int} # How many items the LRU is allowed to store
	lru_mem_capacity::Base.RefValue{Int} # How many bytes the LRU is allowed to store (if not low on memory)
	lru_mem_fraction::Base.RefValue{Float64} # How many bytes the LRU is allowed to store as a fraction of system memory available
	lru::LRUCache{SpecArgs} # To prevent GC of most recently used results
end
function Scheduler(cache::Cache{SpecArgs,H};
	               lru_item_capacity = nothing,
	               lru_mem_capacity = nothing,
	               lru_mem_fraction = nothing) where H

	lru_item_capacity = @something lru_item_capacity 200
	lru_mem_capacity = @something lru_mem_capacity div(Int(Sys.total_memory()), 20)
	lru_mem_fraction = @something lru_mem_fraction 0.1

	Scheduler{H}(cache.deduplicator, cache, Ref(lru_item_capacity), Ref(lru_mem_capacity), Ref(lru_mem_fraction), LRUCache{SpecArgs}())
end
Scheduler(deduplicator::Deduplicator{H}; lru_item_capacity=nothing, lru_mem_capacity=nothing, lru_mem_fraction=nothing, kwargs...) where H =
	Scheduler(Cache(SpecArgs, deduplicator; kwargs...); lru_item_capacity, lru_mem_capacity, lru_mem_fraction)
Scheduler(; kwargs...) = Scheduler(Deduplicator(); kwargs...)


function set_lru_item_capacity!(scheduler::Scheduler, capacity)
	scheduler.lru_item_capacity[] = capacity
	scheduler
end
set_lru_item_capacity!(capacity) = set_lru_item_capacity!(get_scheduler(), capacity)

get_lru_item_capacity(scheduler::Scheduler) = scheduler.lru_item_capacity[]
get_lru_item_capacity() = get_lru_item_capacity(get_scheduler())


function evict_results!(scheduler::Scheduler; evict_all=true)
	lru = scheduler.lru
	item_capacity = scheduler.lru_item_capacity[]
	mem_capacity = min(scheduler.lru_mem_capacity[], round(Int, scheduler.lru_mem_fraction[]*Sys.free_memory()))

	initial_items = length(lru)
	initial_size = lru.total_size
	while !isempty(lru) && (evict_all || length(lru)>item_capacity || lru.total_size>mem_capacity)
		sa = lru_pop!(lru)
		sa !== nothing && empty_result!(sa)
	end

	if length(lru) < initial_items
		e_sz_str = _byte_size_string(initial_size - lru.total_size)
		r_sz_str = _byte_size_string(lru.total_size)
		c_sz_str = _byte_size_string(mem_capacity)
		@info "Evicted: $(initial_items-length(lru)) items ($e_sz_str). Remaining: $(length(lru)) items ($r_sz_str). Capacity: $item_capacity items ($c_sz_str)."
	end

	scheduler
end

function Base.empty!(scheduler::Scheduler)
	evict_results!(scheduler)
	force_empty!(scheduler.lru)
	# empty!(scheduler.deduplicator) # Hmm. This is problematic, because the user can still have specs, and the deduplicator shouldn't lose track of those.
	scheduler
end


fetch_dependencies!(scheduler, deps) = IdDict{WrappedSpec,Any}(dep=>fetch!(scheduler, dep) for dep in deps)



function process_dependency!(scheduler, dep; parent_f)
	dep.op === :call && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f, processing_errors_throw=false)
end
process_dependencies!(scheduler, deps; parent_f) =
	IdDict{WrappedSpec,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)




function propagate_error(sa::SpecArgs, vals)::Union{Nothing, ProcessingException, InterruptException}
	if any(x->x isa InterruptException, vals)
		return InterruptException()
	elseif any(x->x isa ProcessingException, vals)
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

function replace_forwarded(sa::SpecArgs, upstream::IdDict{WrappedSpec,Any})
	err = propagate_error(sa, values(upstream))
	err !== nothing && return err
	return map_args(x->get(upstream,x,nothing), sa)
end


function compute(scheduler::Scheduler, sa::SpecArgs, upstream::IdDict{WrappedSpec,Any})
	f = sa.f
	try
		@info "Running $f"
		err = propagate_error(sa, values(upstream))
		err !== nothing && return err

		v = _get_kwarg(sa, :__version, nothing)
		@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

		sa_replaced = map_args(x->get(upstream,x,nothing), sa)
		args = sa_replaced.args
		kwargs = sa_replaced.kwargs

		# Get rid of kwargs where the key starts with __
		# kwargs = NamedTuple{filter(k->!startswith(string(k),"__"), keys(kwargs))}(kwargs)

		kwargs = filter(p->!startswith(string(p[1]),"__"), kwargs) # TODO: we can probably avoid allocations here, if we can assume that __ kwargs are at always at the beginning/end of the sorted kwargs

		res = f(args...; kwargs...)
		@assert res !== nothing "Computation of $f returned nothing"

		res = deduplicate!(scheduler.deduplicator, res)

		return res
	catch e
		e isa InterruptException && return e

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


function _fetch_and_compute!(scheduler, sa::SpecArgs, deps::Vector{WrappedSpec})
	deps = fetch_dependencies!(scheduler, deps)
	# res = compute(scheduler, sa, deps)

	# DEBUG
	t = @elapsed res = compute(scheduler, sa, deps)
	@info "compute $(sa.f) $(t)s"

	@assert !(res isa WrappedSpec)
	res
end


function _fetch_and_compute_cached!(scheduler, sa::SpecArgs, deps::Vector{WrappedSpec})
	inner_spec = sa.args[1]::WrappedSpec
	inner_sa = get_sa(inner_spec)
	inner_deps = get_dependencies(inner_sa)
	@assert all(s->s.op === :call, inner_deps) # The outer call has enforced all inner specs to be calls has well.

	cache_get!(scheduler.cache, inner_sa) do
		_fetch_and_compute!(scheduler, inner_sa, inner_deps)
	end
end

# TODO: Simplify code
function _fetch_and_compute_sub!(scheduler, sa::SpecArgs, deps::Vector{WrappedSpec})
	@assert sa.f in (compoundresult_sub, compoundresult_keys)

	cached_sa = get_sa(sa.args[1]::WrappedSpec)
	@assert cached_sa.f == get_cached
	cached_deps = get_dependencies(cached_sa)
	@assert all(s->s.op === :call, cached_deps) # The outer call has enforced all sub-specs to be calls has well.

	# Try in this order
	# 0. (Already done) Is it cached and still valid in sa.result.
	# 1. Is the cached_sa result still valid? Then return subresult from that.
	# 2. Can we reconstruct from the cached_sa weak_result?
	# 3. Is the cached_sa cached to disk? Then load the subresult (only) from disk.
	# 4. Compute compoundresult and return sub.

	if sa.f == compoundresult_sub
		sub = sa.args[2]::String
	else #if sa.f == compoundresult_keys
		sub = nothing
	end


	# TODO: Put part of this in a helper function, get_result?, in spec.jl?
	# 1.
	if cached_sa.result !== NotValid()
		@info "Found cached CompoundResult ($(get_sa(cached_sa.args[1]).f))"
		cr = cached_sa.result
		cr isa Exception && return cr
		@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
		return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
	end

	w = cached_sa.weak_result
	if w !== NotValid()
		@info "Attempting 2 ($(get_sa(cached_sa.args[1]).f))"

		# Attempt to reconstruct from weakly stored CompoundResult
		@assert w isa CompoundResult "Expected CompoundResult, got $(typeof(w))."
		# sub === nothing && return get_keys(w)
		sub === nothing && return (@info "2 success $sub ($(get_sa(cached_sa.args[1]).f))"; return get_keys(w))
		v = reconstruct_weak_rec(get_subresult(w, sub))
		# v !== NotValid() && return v
		v !== NotValid() && (@info "2 success $sub ($(get_sa(cached_sa.args[1]).f))"; return v)
		@info "2 failed ($(get_sa(cached_sa.args[1]).f))"
	end

	# 3.
	inner_sa = get_sa(cached_sa.args[1])
	@info "Attempting 3 ($(get_sa(cached_sa.args[1]).f))"
	v = cache_try_get_compoundresult(scheduler.cache, inner_sa; sub, return_keys=sub===nothing)
	# v !== NotValid() && return v
	v !== NotValid() && (@info "3 success $sub ($(get_sa(cached_sa.args[1]).f))"; return v)
	@info "3 failed ($(get_sa(cached_sa.args[1]).f))"

	# 4.
	@info "Attempting 4 ($(get_sa(cached_sa.args[1]).f))"
	cr = get_result!(cached_sa) do # This is to ensure cached_sa.result gets set, maybe use set_result! instead? Because we should never reach here if cached_sa.result !== nothing.
		_fetch_and_compute_cached!(scheduler, cached_sa, cached_deps)
	end
	cr isa Exception && return cr
	cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))

	lru_touch!(scheduler.lru, inner_sa) do
		Base.summarysize(cr)
	end

	return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
end



function _process_once!(scheduler::Scheduler, sa::SpecArgs, deps::Vector{WrappedSpec})
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sa.f)

	if !isempty(forwarded_deps)
		sa = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
	end

	if is_preprocessing(sa)
		# preprocess(scheduler, sa)

		# DEBUG
		t = @elapsed res = preprocess(scheduler, sa)
		@info "preprocess $(sa.f) $(t)s"
		res
	else
		sa isa ProcessingException && return sa

		sa = deduplicate!(scheduler.deduplicator, sa)
		WrappedSpec(sa, :call)
	end
end





# TODO: Move these somewhere else?
# These functions are actually never called. We just use them as singleton values to show that something is using the on-disk cache.
function compoundresult_sub end
function compoundresult_keys end
function get_cached end

function cached(spec::WrappedSpec, sub::Union{Nothing,String}=nothing; return_keys::Bool=false)
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
function process_once!(scheduler::Scheduler, sa::SpecArgs, op::Symbol; parent_f)
	if parent_f !== nothing && op in (:forward,:prefetch)
		if !should_forward_child(parent_f, sa.f)
			return (WrappedSpec(sa, op), true)
		end
	end

	deps = get_dependencies(sa)

	if !is_preprocessing(sa) && all(x->x.op === :call, deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		op === :forward && return (WrappedSpec(sa, :call), true)

		res = get_result!(sa) do
			# # DEBUG
			# h = lookup_hash(scheduler.deduplicator, sa)
			# @info "Computing $(sa.f) ($(hash_string(h)[1:6]), n=$(processing_count(h)))"

			if sa.f == compoundresult_sub || sa.f == compoundresult_keys
				_fetch_and_compute_sub!(scheduler, sa, deps)
			elseif sa.f == get_cached
				_fetch_and_compute_cached!(scheduler, sa, deps)
			else
				_fetch_and_compute!(scheduler, sa, deps)
			end
		end
		@assert !(res isa CompoundResult) # Is this a good place to check? Maybe should be ensured earlier.
		@assert !(res isa WrappedSpec)

		lru_touch!(scheduler.lru, sa) do
			Base.summarysize(res)
		end


		return res, true
	end

	res = get_next!(sa) do
		# # DEBUG
		# h = lookup_hash(scheduler.deduplicator, sa)
		# @info "Preprocessing $(sa.f) ($(hash_string(h)[1:6]), n=$(processing_count(h)))"

		_process_once!(scheduler, sa, deps)
	end

	if res isa WrappedSpec
		return res, false
	else
		return res, true # forwarding returned a value, we are done
	end
end


function process!(scheduler::Scheduler, sa::SpecArgs, op::Symbol; parent_f=nothing, processing_errors_throw=true)
	evict_results!(scheduler; evict_all=false)

	while true
		res, done = process_once!(scheduler, sa, op; parent_f)
		# done && return res
		if done
			processing_errors_throw && res isa Exception && throw(res)
			return res
		end
		res::WrappedSpec
		sa = get_sa(res)
		# NB: Keep the op
	end
end


fetch!(scheduler::Scheduler, ws::WrappedSpec; kwargs...) = process!(scheduler, get_sa(ws), :fetch; kwargs...)
forward!(scheduler::Scheduler, ws::WrappedSpec; kwargs...) = process!(scheduler, get_sa(ws), :forward; kwargs...)
process!(scheduler::Scheduler, ws::WrappedSpec; kwargs...) = process!(scheduler, get_sa(ws), ws.op; kwargs...)

function forward_once!(scheduler::Scheduler, ws::WrappedSpec; parent_f=nothing, processing_errors_throw=true)
	res, _ = process_once!(scheduler, get_sa(ws), :forward; parent_f)
	processing_errors_throw && res isa Exception && throw(res)
	res
end


fetch!(ws::WrappedSpec; kwargs...) = fetch!(get_scheduler(), ws; kwargs...)
forward!(ws::WrappedSpec; kwargs...) = forward!(get_scheduler(), ws; kwargs...)
forward_once!(ws::WrappedSpec; kwargs...) = forward_once!(get_scheduler(), ws; kwargs...)
process!(ws::WrappedSpec; kwargs...) = process!(get_scheduler(), ws; kwargs...)



# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	print(io, scheduler.lru)
	print(io,')')
end
