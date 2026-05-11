struct WorkCompute
	sr::SpecRun
end
struct WorkPreprocess
	sr::SpecRun
end
struct WorkDeduplicateResult
	sr::SpecRun
	obj::Any
end

const WorkUnion = Union{WorkCompute, WorkPreprocess, WorkDeduplicateResult}


mutable struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{SpecRun,H} # sr -> result stored on disk

	processing_queue::Vector{SpecRun} # lifo queue of specs ready to be posted to the work_channel

	work_task_world_age::UInt64 # world_age when work_task was started (so we can restart it if world age has changed)
	work_task::Union{Task,Nothing}
	work_channel::Channel{WorkUnion}
	result_channel::Channel{Any} # later maybe change to Tuple{SpecRun,Any} if we have multiple worker tasks

	lru_item_capacity::Base.RefValue{Int} # How many items the LRU is allowed to store
	lru_mem_capacity::Base.RefValue{Int} # How many bytes the LRU is allowed to store (if not low on memory)
	lru_mem_fraction::Base.RefValue{Float64} # How many bytes the LRU is allowed to store as a fraction of system memory available
	lru::LRUCache{SpecRun} # To prevent GC of most recently used results

	# Progress display and related
	progress_display::ProgressDisplay
	lru_display_item::Base.RefValue{Union{ProgressText,Nothing}}
	gc_display_item::Base.RefValue{Union{ProgressText,Nothing}}
	# preprocess_display_item::Base.RefValue{Union{ProgressText,Nothing}} # We reuse a single display item for preprocessing, to avoid flooding the terminal
	# deduplication_display_item::Base.RefValue{Union{ProgressText,Nothing}} # We reuse a single display item for deduplication, to avoid flooding the terminal
end
function Scheduler(cache::Cache{SpecRun,H};
	               lru_item_capacity = nothing,
	               lru_mem_capacity = nothing,
	               lru_mem_fraction = nothing) where H

	lru_item_capacity = @something lru_item_capacity 200
	lru_mem_capacity = @something lru_mem_capacity div(Int(Sys.total_memory()), 20)
	lru_mem_fraction = @something lru_mem_fraction 0.1

	work_channel = Channel{WorkUnion}(Inf)
	result_channel = Channel{Any}(Inf)

	scheduler = Scheduler{H}(cache.deduplicator, cache, SpecRun[], UInt64(0), nothing, work_channel, result_channel, Ref(lru_item_capacity), Ref(lru_mem_capacity), Ref(lru_mem_fraction), LRUCache{SpecRun}(), ProgressDisplay(), Ref{Union{ProgressText,Nothing}}(nothing), Ref{Union{ProgressText,Nothing}}(nothing))

	# Move to inner constructor?
    finalizer(scheduler) do s
        close(s.work_channel)
        close(s.result_channel)
    end

	scheduler
end
Scheduler(deduplicator::Deduplicator{H}; lru_item_capacity=nothing, lru_mem_capacity=nothing, lru_mem_fraction=nothing, kwargs...) where H =
	Scheduler(Cache(SpecRun, deduplicator; kwargs...); lru_item_capacity, lru_mem_capacity, lru_mem_fraction)
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
	# mem_capacity = min(scheduler.lru_mem_capacity[], round(Int, scheduler.lru_mem_fraction[]*Sys.free_memory())) # NB: Sys.free_memory is a bad way to measure this. Julia doesn't always return memory to the system.
	mem_capacity = scheduler.lru_mem_capacity[]

	initial_items = length(lru)
	initial_size = lru.total_size
	while !isempty(lru) && (evict_all || length(lru)>item_capacity || lru.total_size>mem_capacity)
		sr = lru_pop!(lru)
		sr !== nothing && empty_result!(sr)
	end

	# if length(lru) < initial_items
	# 	e_sz_str = _byte_size_string(initial_size - lru.total_size)
	# 	r_sz_str = _byte_size_string(lru.total_size)
	# 	c_sz_str = _byte_size_string(mem_capacity)
	# 	@info "Evicted: $(initial_items-length(lru)) items ($e_sz_str). Remaining: $(length(lru)) items ($r_sz_str). Capacity: $item_capacity items ($c_sz_str)."
	# end

	# r_sz_str = _byte_size_string(lru.total_size)
	# c_sz_str = _byte_size_string(mem_capacity)
	r_sz_str = Base.format_bytes(lru.total_size; binary=false)
	c_sz_str = Base.format_bytes(mem_capacity; binary=false)
	# set_text!(scheduler.lru_display_item[], "⋅ LRU: $(length(lru))/$item_capacity items ($r_sz_str/$c_sz_str)")
	if scheduler.lru_display_item[] !== nothing
		set_text!(scheduler.progress_display, scheduler.lru_display_item[], styled"{blue:⋅ LRU:} $(length(lru))/$item_capacity items ($r_sz_str/$c_sz_str)")
	end

	scheduler
end
evict_results!(; kwargs...) = evict_results!(get_scheduler(); kwargs...)

function Base.empty!(scheduler::Scheduler)
	evict_results!(scheduler)
	force_empty!(scheduler.lru)
	# empty!(scheduler.deduplicator) # Hmm. This is problematic, because the user can still have specs, and the deduplicator shouldn't lose track of those.

	# Shut down the previous worker task
	close(scheduler.work_channel)
	close(scheduler.result_channel)
	scheduler.work_task = nothing

	scheduler.work_channel = Channel{WorkUnion}(Inf)
	scheduler.result_channel = Channel{Any}(Inf)

	scheduler
end


# old
fetch_dependencies!(scheduler, deps) = IdDict{SpecRef,Any}(dep=>fetch!(scheduler, dep; external_call=false) for dep in deps)

# old
function process_dependency!(scheduler, dep; @nospecialize(parent_f))
	dep.op === :call && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f, processing_errors_throw=false, external_call=false)
end
process_dependencies!(scheduler, deps; @nospecialize(parent_f)) =
	IdDict{SpecRef,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)




function propagate_error(sr::SpecRun, vals)::Union{Nothing, ProcessingException}#, InterruptException}
	# if any(x->x isa InterruptException, vals)
	# 	return InterruptException()
	# elseif any(x->x isa ProcessingException, vals)
	if any(x->x isa ProcessingException, vals)
		causes = filter!(x->x isa ProcessingException, collect(vals))
		return ProcessingException(sr, causes)
	else
		return nothing
	end
end



function ensure_work_task_is_running!(scheduler::Scheduler)
	if scheduler.work_task === nothing || istaskdone(scheduler.work_task) || istaskfailed(scheduler.work_task) || Base.get_world_counter() != scheduler.work_task_world_age
		empty!(scheduler.work_channel)
		empty!(scheduler.result_channel)
		scheduler.work_task_world_age = Base.get_world_counter()
		# @info "Spawning work task"
		scheduler.work_task = Threads.@spawn work_runner(scheduler, scheduler.work_channel, scheduler.result_channel)
	end
	scheduler
end

function _short_exception_string(e::Exception; n::Int=40)
	n = max(n,3) # need space for ellipsis
	s = string(e)
	s = replace(s, r"\r\n|\r|\n" => " ") # replace line breaks with space
	length(s) > n && (s = s[1:n-3]*"...")
	s
end


function work_run_single(scheduler, work::WorkUnion, result_channel::Channel)
	progress_display = scheduler.progress_display
	progress_item = nothing
	sr = work.sr::SpecRun

	local res
	try
		f = sr.f

		# NB: Deduplication and thus also Preprocessing are not thread-safe and is thus currently assumed to not happen in parallel
		if work isa WorkPreprocess
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Preprocessing} " * ReproducibleJobs.styled_function_name(f)))
			res = f(sr.args...; sr.kwargs...)
			@assert res !== nothing "Preprocessing of $f returned nothing"
			remove_item!(progress_display, progress_item)
		elseif work isa WorkCompute
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Running} " * ReproducibleJobs.styled_function_name(f)))

			v = _get_kwarg(sr, :__version, nothing)
			@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

			kwargs = Iterators.filter(p->!startswith(string(p[1]),"__"), sr.kwargs)
			res = f(sr.args...; kwargs...)
			@assert res !== nothing "Computation of $f returned nothing"
			remove_item!(progress_display, progress_item)
		elseif work isa WorkDeduplicateResult
			# TODO: Only show deduplication message if it takes time (>0.1s).
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Deduplicating }" * ReproducibleJobs.styled_function_name(f); type=:pending))
			res = deduplicate!(scheduler.deduplicator, work.obj; transfer_ownership=true) # Since it is a result, we know that we own the data
			remove_item!(progress_display, progress_item)
		end
	catch e
		exception_text = _short_exception_string(e)
		progress_item !== nothing && remove_item!(progress_display, progress_item, styled"{red:$exception_text}")
		# TODO: Where to show error?
		# io = IOBuffer()
		# Base.showerror(IOContext(io, :color=>true), e)
		# message = String(take!(io))
		# @warn message

		# Do not show anything/much here, it will be shown later instead.
		bt = Base.catch_backtrace()
		res = ProcessingException(sr, e, stacktrace(bt))
	end

	put!(result_channel, res)
end


# Hmm. Maybe better to not pass scheduler - seems like that might prevent GC of scheduler if restarted.
function work_runner(scheduler::Scheduler, work_channel::Channel{WorkUnion}, result_channel::Channel{Any})
	for work in work_channel # will exit when work_channel is closed
		work_run_single(scheduler, work, result_channel) # Do this in a separate function to enable GC to run properly.
	end
end


function process_work(scheduler, work::WorkUnion)
	progress_display = scheduler.progress_display
	put!(scheduler.work_channel, work)

	done = false
	# Ensure the channel receives items periodically so we can display updates
	@async begin
		while !done
			put!(scheduler.result_channel, nothing) # Maybe use something else than nothing to signal the timeout
			sleep(0.05)
		end
	end

	local res

	while !done
		if istaskfailed(scheduler.work_task) || istaskdone(scheduler.work_task)
			done = true
			fetch(scheduler.work_task) # will throw if the task threw an exception
			error("Unknown work_task failure")
		end

		res = take!(scheduler.result_channel)
		if res === nothing # Timed out
			print_display(progress_display)
		else
			done = true
		end
	end

	res
end


# preprocess(::Scheduler, err::Exception) = err

function preprocess(scheduler::Scheduler, sr::SpecRun)
	res = process_work(scheduler, WorkPreprocess(sr))
	res = process_work(scheduler, WorkDeduplicateResult(sr, res))
end



# compute(::Scheduler, err::Exception) = err

function compute(scheduler::Scheduler, sr::SpecRun)
	res = process_work(scheduler, WorkCompute(sr))
	res = process_work(scheduler, WorkDeduplicateResult(sr, res))
end




function replace_dependencies(sr::SpecRun, upstream::IdDict{SpecRef,Any})
	err = propagate_error(sr, values(upstream))
	err !== nothing && return err
	return map_args(x->get(upstream,x,nothing), sr)
end
function replace_dependencies(sr::SpecRun, upstream::IdDict{Tuple{SpecRun,Symbol},Any}) # Ugly def since Julia currently doesn't support mutually recursive types
	err = propagate_error(sr, values(upstream))
	err !== nothing && return err
	# return map_args(x->get(upstream, x, nothing), sr)
	return map_args(x->(x isa SpecRef) ? get(upstream, (x.sr,x.op), nothing) : nothing, sr) # Ugly - See above. TODO: Make less ugly.
end

function _fetch_and_compute!(scheduler, sr::SpecRun, deps::Vector{SpecRef})
	# TODO: Check that sr.state is as expected?
	sr.state = SpecWaiting()
	fetched_deps = fetch_dependencies!(scheduler, deps)

	sa_replaced = sr
	if !isempty(fetched_deps)
		sa_replaced = replace_dependencies(sr, fetched_deps)::Union{SpecRun,ProcessingException,InterruptException}
	end
	sr.state = SpecProcessing()
	res = compute(scheduler, sa_replaced)
	@assert !(res isa SpecRef)
	return res
end


function _fetch_and_compute_cached!(scheduler, sr::SpecRun, deps::Vector{SpecRef})
	inner_spec = sr.args[1]::SpecRef
	inner_sr = get_sr(inner_spec)
	inner_deps = get_dependencies(inner_sr)
	@assert all(s->s.op === :call, inner_deps) # The outer call has enforced all inner specs to be calls has well.

	sr.state = SpecWaiting()
	cache_get!(scheduler.cache, inner_sr) do
		_fetch_and_compute!(scheduler, inner_sr, inner_deps)
	end
end

# TODO: Simplify code
function _fetch_and_compute_sub!(scheduler, sr::SpecRun, deps::Vector{SpecRef})
	@assert sr.f in (compoundresult_sub, compoundresult_keys)

	cached_sr = get_sr(sr.args[1]::SpecRef)
	@assert cached_sr.f == get_cached
	cached_deps = get_dependencies(cached_sr)
	@assert all(s->s.op === :call, cached_deps) # The outer call has enforced all sub-specs to be calls has well.

	sr.state = SpecWaiting()

	# Try in this order
	# 0. (Already done) Is it cached and still valid in sr.result.
	# 1. Is the cached_sr result still valid? Then return subresult from that.
	# 2. Can we reconstruct from the cached_sr weak_result?
	# 3. Is the cached_sr cached to disk? Then load the subresult (only) from disk.
	# 4. Compute compoundresult and return sub.

	if sr.f == compoundresult_sub
		sub = sr.args[2]::String
	else #if sr.f == compoundresult_keys
		sub = nothing
	end


	if cached_sr.state isa SpecResult
		# 1.
		if cached_sr.state.result !== NotValid()
			cr = cached_sr.state.result
			cr isa Exception && return cr
			@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
			return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
		end

		# 2.
		w = cached_sr.state.weak_result
		if w !== NotValid()
			@assert w isa CompoundResult "Expected CompoundResult, got $(typeof(w))."
			sub === nothing && return get_keys(w)
			v = reconstruct_weak_rec(get_subresult(w, sub))
			v !== NotValid() && return v
		end
	end


	# 3.
	inner_sr = get_sr(cached_sr.args[1])
	v = cache_try_get_compoundresult(scheduler.cache, inner_sr; sub, return_keys=sub===nothing)
	v !== NotValid() && return v

	cr = _fetch_and_compute_cached!(scheduler, cached_sr, cached_deps)
	set_result!(cached_sr, cr)

	cr isa Exception && return cr

	lru_touch!(scheduler.lru, inner_sr) do
		Base.summarysize(cr)
	end

	cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))

	return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
end



function _process_once!(scheduler::Scheduler, sr::SpecRun, deps::Vector{SpecRef})
	sr.state = SpecWaiting()
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sr.f)

	sr_replaced = sr
	if !isempty(forwarded_deps)
		sr_replaced = replace_dependencies(sr, forwarded_deps)::Union{SpecRun,ProcessingException,InterruptException}
	end

	sr_replaced isa Exception && return sr_replaced

	if is_preprocessing(sr_replaced)
		sr.state = SpecProcessing()
		preprocess(scheduler, sr_replaced)
	else
		sr_replaced = deduplicate!(scheduler.deduplicator, sr_replaced)
		SpecRef(sr_replaced, :call)
	end
end





# TODO: Move these somewhere else?
# These functions are actually never called. We just use them as singleton values to show that something is using the on-disk cache.
function compoundresult_sub end
function compoundresult_keys end
function get_cached end

function cached(ref::SpecRef, sub::Union{Nothing,String}=nothing; return_keys::Bool=false)
	@assert sub==nothing || return_keys==false

	c = create_spec(get_cached, ref; __version=v"1.0.0")
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
# function cached(ref, sub::String...; return_keys=false)
# 	extra_kwargs = (return_keys ? (; return_keys) : (;)) # only pass kwarg if set to true
# 	create_spec(get_cached, ref, sub...; extra_kwargs..., __version=v"1.0.0")
# end





# Return tuple with result and Bool telling if it's done (TODO: Make code more clear)
function process_once!(scheduler::Scheduler, sr::SpecRun, op::Symbol)
	deps = get_dependencies(sr)

	if !is_preprocessing(sr) && all(x->x.op === :call, deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		op === :forward && return (SpecRef(sr, :call), true)

		# Already computed?
		res = get_result!(sr)
		res !== NotValid() && return (res, true)

		if sr.f == compoundresult_sub || sr.f == compoundresult_keys
			res = _fetch_and_compute_sub!(scheduler, sr, deps)
		elseif sr.f == get_cached
			res = _fetch_and_compute_cached!(scheduler, sr, deps)
		else
			res = _fetch_and_compute!(scheduler, sr, deps)
		end

		@assert !(res isa CompoundResult) # Is this a good place to check? Maybe should be ensured earlier.
		@assert !(res isa SpecRef)

		lru_touch!(scheduler.lru, sr) do
			Base.summarysize(res)
		end

		set_result!(sr, res)
		return res, true
	end

	# Cached forwarding
	sr.state isa SpecNext{SpecRun} && return (SpecRef(sr.state), false)

	# Cached result
	res = get_result!(sr)
	res !== NotValid() && return (res, true)

	# Preprocess
	res = _process_once!(scheduler, sr, deps)
	if res isa SpecRef
		sr.state = SpecNext(res)
		return res, false # Still forwarding, not done.
	end

	set_result!(sr, res) # Preprocessing yielded a result, we are done.
	return res, true
end


# function setup_dependency!(scheduler, sr::SpecRun, op; @nospecialize parent_f)
# 	if parent_f !== nothing && op in (:forward,:prefetch) && !should_forward_child(parent_f, sr.f)
# 		return SpecRef(sr, op) # processing done, we shouldn't forward anymore
# 	end
# 	setup_processing!(scheduler, sr, op)
# end

function setup_dependency!(scheduler, sr::SpecRun, call::Bool, dep::SpecRef)
	curr::SpecRef = dep
	if call
		@assert curr.op == :call
		next = setup_processing!(scheduler, curr)
	else
		# stop before calling
		next = dep
		while curr.op !== :call && should_forward_child(sr.f, curr.sr.f)
			next = setup_processing!(scheduler, curr)
			next isa SpecRef || break
			curr = next
		end
	end

	# first attempt
	# curr::SpecRef = next = dep
	# while !(op in (:forward,:prefetch)) || should_forward_child(sr.f, curr.sr.f)
	# 	# next = setup_dependency!(scheduler, curr.sr, curr.op; parent_f=sr.f)
	# 	next = setup_processing!(scheduler, curr)
	# 	next isa SpecRef || break
	# 	curr = next
	# end

	if next === NotValid() # we are waiting for an upstream spec to process
		w = curr.sr.state::Union{SpecWaiting{SpecRun},SpecProcessing{SpecRun}}
		push!(w.downstream, (sr,(dep.sr,dep.op))) # TODO: Make utility function to avoid ugly tuples here
		# n_upstream_left += 1
	end

	# upstream[(dep.sr, dep.op)] = next

	next
end


# WIP
# This function will do one of the following:
# 1. return the preprocessed spec/result if there is one cached
# 2. return the computed result if there is one cached
# 3. push the spec to the processing queue (if all dependencies are ready)
# 4. set it up to wait for dependencies to finish processing
# It may also recursively call setup_processing for the dependencies.
function setup_processing!(scheduler, ref)
	sr, op = ref.sr, ref.op
	@info "setup_processing!: $(sr.f)"

	# Cached forwarding
	sr.state isa SpecNext{SpecRun} && return SpecRef(sr.state)

	if is_preprocessing(sr)
		# Cached result
		res = get_result!(sr)
		res !== NotValid() && return res # Early out for preprocessing specs - it **preprocessed** to a result
	end

	deps = get_dependencies(sr)

	ready_to_call = !is_preprocessing(sr) && all(x->x.op === :call, deps)

	if op === :forward && ready_to_call
		return SpecRef(sr, :call) # We cannot forward any further (Hmm. Should we ever get here? I think we want to prevent this case at an earlier step.)
	end

	if !is_preprocessing(sr)
		# Cached result
		res = get_result!(sr)
		res !== NotValid() && return res # Early out for computing specs
	end


	# @show deps
	# @show ready_to_call

	# @show sr
	# @show deps
	# @show getfield.(deps, :op)


	# # Maybe handle get_cached etc here?
	# if ready_to_call && sr.f == get_cached
	# 	@info "mmhm."
	# end

	# # This *might* be needed
	# if sr.f == get_cached
	# 	ready_to_call = false
	# end



	upstream = IdDict{Tuple{SpecRun,Symbol},Any}()
	n_upstream_left = 0
	for dep in deps
		# curr::SpecRef = next = dep
		# while !(op in (:forward,:prefetch)) || should_forward_child(sr.f, dep.sr.f)
		# 	# next = setup_dependency!(scheduler, curr.sr, curr.op; parent_f=sr.f)
		# 	next = setup_processing!(scheduler, curr.sr, curr.op)
		# 	next isa SpecRef || break
		# 	curr = next
		# end
		
		# upstream[(dep.sr, dep.op)] = next
		# if next === NotValid() # we are waiting for an upstream spec to process
		# 	w = curr.sr.state::Union{SpecWaiting{SpecRun},SpecProcessing{SpecRun}}
		# 	push!(w.downstream, (sr,(dep.sr,dep.op))) # TODO: Make utility function to avoid ugly tuples here
		# 	n_upstream_left += 1
		# end

		next = setup_dependency!(scheduler, sr, ready_to_call, dep)
		# @show next
		# @show next === dep
		if next !== NotValid() # Did we get a value?
			upstream[(dep.sr, dep.op)] = next
		else
			n_upstream_left += 1
		end
	end


	# TESTING - this shows that I was missing forwarding to a spec with all deps :call before actually computing
	if !ready_to_call && n_upstream_left == 0 && !is_preprocessing(sr.f)
		sa_replaced = sr
		if !isempty(upstream)
			sa_replaced = replace_dependencies(sr, upstream)::Union{SpecRun,ProcessingException}
		end
		if sa_replaced isa ProcessingException
			set_result!(sr, sa_replaced)
			return sa_replaced
		else
			sa_replaced::SpecRun
			sr.state = SpecNext(sa_replaced, op) # Keep the op?
			return SpecRef(sr.state)
		end
	end


	# @show n_upstream_left
	sr.state = SpecWaiting(upstream, n_upstream_left, ready_to_call)
	# n_upstream_left == 0 && push!(scheduler.processing_queue, sr) # ready to be processed

	# DEBUG
	if n_upstream_left == 0
		@info "1: Pushed $(sr.f) to processing queue"

		# @show sr
		# @show sr.state

		push!(scheduler.processing_queue, sr) # ready to be processed
	end


	return NotValid() # Not yet available (TODO: Use something else to signal this?)
end




function _reset_progress_display!(scheduler, sr::SpecRun)
	empty!(scheduler.progress_display)
	add_item!(scheduler.progress_display, ProgressText(styled"{blue:Scheduler: }" * ReproducibleJobs.styled_function_name(sr.f)))
	scheduler.gc_display_item[] = add_item!(scheduler.progress_display, ProgressText(styled"{blue:⋅ GC:}"; type=:text))
	scheduler.lru_display_item[] = add_item!(scheduler.progress_display, ProgressText(styled"{blue:⋅ LRU:}"; type=:text))
end

function _update_gc_display!(scheduler::Scheduler)
	live = Base.format_bytes(Base.gc_live_bytes(); binary=false)
	# More stuff? E.g. time since last full/incremental sweep. And max memory usage.
	set_text!(scheduler.progress_display, scheduler.gc_display_item[], styled"{blue:⋅ GC:} $live live")
end


# Old
# TODO: Avoid passing parent_f which can have many different types and just pass sufficient info to make this decision? Then we can get rid of @nospecialize...
function process!(scheduler::Scheduler, sr::SpecRun, op::Symbol; @nospecialize(parent_f=nothing), processing_errors_throw=true, external_call=true)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, sr)
	end
	evict_results!(scheduler; evict_all=false)
	_update_gc_display!(scheduler)

	while true
		if parent_f !== nothing && op in (:forward,:prefetch) && !should_forward_child(parent_f, sr.f)
			return SpecRef(sr, op) # processing done, we shouldn't forward anymore
		end

		res, done = process_once!(scheduler, sr, op)
		# done && return res
		if done
			processing_errors_throw && res isa Exception && throw(res)
			return res
		end
		res::SpecRef
		sr = get_sr(res)
		# NB: Keep the op
	end
end


function _update_downstream!(scheduler::Scheduler, downstream::Vector{Tuple{SpecRun,Tuple{SpecRun,Symbol}}}, res)
	for (sr,(dep_sr,dep_op)) in downstream
		state = sr.state::SpecWaiting

		# update state, and either continue processing the dep or insert the value (next/result)
		next = setup_dependency!(scheduler, sr, state.ready_to_call, SpecRef(dep_sr,dep_op))
		if next !== NotValid() # Did we get a value?
			state.upstream[(dep.sr, dep.op)] = next
			state.n_upstream_left[] -= 1
			# state.n_upstream_left[] == 0 && push!(scheduler.processing_queue, sr) # Ready to process the owning spec
			
			# DEBUG
			if state.n_upstream_left[] == 0
				@info "2: Pushed $(sr.f) to processing queue"
				push!(scheduler.processing_queue, sr) # Ready to process the owning spec
			end
		end
	end
end



function process_once_new!(scheduler::Scheduler, sr::SpecRun)
	state = sr.state::SpecWaiting
	@assert state.n_upstream_left[] == 0

	sa_replaced = sr
	if !isempty(state.upstream)
		sa_replaced = replace_dependencies(sr, state.upstream)::Union{SpecRun,ProcessingException}
	end
	sa_replaced isa Exception && return sa_replaced

	sr.state = SpecProcessing(state.downstream)
	if is_preprocessing(sr.f)
		res = preprocess(scheduler, sa_replaced)
		if res isa SpecRef
			sr.state = SpecNext(res)
			return res
		end
		set_result!(sr, res) # Preprocessing yielded a result, we are done.
		return res
	else
		# Hmm. We currently reach here with uncomputed specs! That was not the intention.
		@info "process_once_new!"
		sr.f == get_cached && @show sa_replaced

		# TODO: Support these (probably during `setup_processing!`?)
		@assert sr.f != compoundresult_sub
		@assert sr.f != compoundresult_keys
		@assert sr.f != get_cached

		res = compute(scheduler, sa_replaced)
		@assert !(res isa CompoundResult) # Is this a good place to check? Maybe should be ensured earlier.
		@assert !(res isa SpecRef)

		lru_touch!(scheduler.lru, sr) do
			Base.summarysize(res)
		end
		set_result!(sr, res)
		return res
	end
end

function process_new!(scheduler::Scheduler, ref::SpecRef; processing_errors_throw=true, external_call=true)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, ref.sr)
	end
	evict_results!(scheduler; evict_all=false)
	_update_gc_display!(scheduler)


	# TODO: simplify code, should just be one loop - no nesting
	while true
		res = setup_processing!(scheduler, ref)

		if res === NotValid()
			while !isempty(scheduler.processing_queue)
				curr_sr = pop!(scheduler.processing_queue) # LIFO
				@info "Popped $(curr_sr.f) from processing queue"
				@show typeof(curr_sr.state)
				# @show typeof(curr_sr.state)
				# @show curr_sr.state.n_upstream_left
				# @show curr_sr.state.upstream
				res = process_once_new!(scheduler, curr_sr)
				processing_errors_throw && res isa Exception && throw(res)
			end
		end

		if res isa SpecRef
			ref.op == :forward && res.op == :call && return SpecRef(res.sr, :forward) # is this the right stop criterion?

			ref = res # TODO: Transfer op from ref?
		else
			return res
		end
	end


	# # TODO: This currently only forwards `spec` once. Fix.
	# setup_processing!(scheduler, spec)

	# while !isempty(scheduler.processing_queue)
	# 	curr_sr = pop!(scheduler.processing_queue) # LIFO
	# 	@info "Popped $(curr_sr.f) from processing queue"
	# 	# @show typeof(curr_sr.state)
	# 	# @show curr_sr.state.n_upstream_left
	# 	# @show curr_sr.state.upstream
	# 	res = process_once_new!(scheduler, curr_sr)
	# 	processing_errors_throw && res isa Exception && throw(res)
	# end

	# # DEBUG
	# spec.sr.state isa SpecNext && return SpecRef(spec.sr.state)


	# return get_result!(spec.sr) # Hmm. Not good enough. The result might be GCed before this! We need to store it in a fake `upstream` or similar. (I guess it works currently because this spec is processed last and the item will thus be in the LRU.)
end



fetch!(scheduler::Scheduler, ref::SpecRef; kwargs...) = process!(scheduler, get_sr(ref), :fetch; kwargs...)
forward!(scheduler::Scheduler, ref::SpecRef; kwargs...) = process!(scheduler, get_sr(ref), :forward; kwargs...)
process!(scheduler::Scheduler, ref::SpecRef; kwargs...) = process!(scheduler, get_sr(ref), ref.op; kwargs...)


function forward_once!(scheduler::Scheduler, ref::SpecRef; processing_errors_throw=true, external_call=true)
	sr = get_sr(ref)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, sr)
	end
	evict_results!(scheduler; evict_all=false)
	_update_gc_display!(scheduler)
	res, _ = process_once!(scheduler, sr, :forward)
	processing_errors_throw && res isa Exception && throw(res)
	res
end


fetch!(ref::SpecRef; kwargs...) = fetch!(get_scheduler(), ref; kwargs...)
forward!(ref::SpecRef; kwargs...) = forward!(get_scheduler(), ref; kwargs...)
forward_once!(ref::SpecRef; kwargs...) = forward_once!(get_scheduler(), ref; kwargs...)
process!(ref::SpecRef; kwargs...) = process!(get_scheduler(), ref; kwargs...)



# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	print(io, scheduler.lru)
	print(io,')')
end
