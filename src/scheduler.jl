# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.


struct WorkCompute
	sa::SpecArgs
end
struct WorkPreprocess
	sa::SpecArgs
end
struct WorkDeduplicateResult
	sa::SpecArgs
	obj::Any
end

const WorkUnion = Union{WorkCompute, WorkPreprocess, WorkDeduplicateResult}


mutable struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{SpecArgs,H} # sa -> result stored on disk

	work_task_world_age::UInt64 # world_age when work_task was started (so we can restart it if world age has changed)
	work_task::Union{Task,Nothing}
	work_channel::Channel{WorkUnion}
	result_channel::Channel{Any} # later maybe change to Tuple{SpecArgs,Any} if we have multiple worker tasks

	lru_item_capacity::Base.RefValue{Int} # How many items the LRU is allowed to store
	lru_mem_capacity::Base.RefValue{Int} # How many bytes the LRU is allowed to store (if not low on memory)
	lru_mem_fraction::Base.RefValue{Float64} # How many bytes the LRU is allowed to store as a fraction of system memory available
	lru::LRUCache{SpecArgs} # To prevent GC of most recently used results

	# Progress display and related
	progress_display::ProgressDisplay
	lru_display_item::Base.RefValue{Union{ProgressItem,Nothing}}
	# preprocess_display_item::Base.RefValue{Union{ProgressItem,Nothing}} # We reuse a single display item for preprocessing, to avoid flooding the terminal
	# deduplication_display_item::Base.RefValue{Union{ProgressItem,Nothing}} # We reuse a single display item for deduplication, to avoid flooding the terminal
end
function Scheduler(cache::Cache{SpecArgs,H};
	               lru_item_capacity = nothing,
	               lru_mem_capacity = nothing,
	               lru_mem_fraction = nothing) where H

	lru_item_capacity = @something lru_item_capacity 200
	lru_mem_capacity = @something lru_mem_capacity div(Int(Sys.total_memory()), 20)
	lru_mem_fraction = @something lru_mem_fraction 0.1

	work_channel = Channel{WorkUnion}(Inf)
	result_channel = Channel{Any}(Inf)

	scheduler = Scheduler{H}(cache.deduplicator, cache, UInt64(0), nothing, work_channel, result_channel, Ref(lru_item_capacity), Ref(lru_mem_capacity), Ref(lru_mem_fraction), LRUCache{SpecArgs}(), ProgressDisplay(), Ref{Union{ProgressItem,Nothing}}(nothing))

	# Move to inner constructor?
    finalizer(scheduler) do s
        close(s.work_channel)
        close(s.result_channel)
    end

	scheduler
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
	# mem_capacity = min(scheduler.lru_mem_capacity[], round(Int, scheduler.lru_mem_fraction[]*Sys.free_memory())) # NB: Sys.free_memory is a bad way to measure this. Julia doesn't always return memory to the system.
	mem_capacity = scheduler.lru_mem_capacity[]

	initial_items = length(lru)
	initial_size = lru.total_size
	while !isempty(lru) && (evict_all || length(lru)>item_capacity || lru.total_size>mem_capacity)
		sa = lru_pop!(lru)
		sa !== nothing && empty_result!(sa)
	end

	# if length(lru) < initial_items
	# 	e_sz_str = _byte_size_string(initial_size - lru.total_size)
	# 	r_sz_str = _byte_size_string(lru.total_size)
	# 	c_sz_str = _byte_size_string(mem_capacity)
	# 	@info "Evicted: $(initial_items-length(lru)) items ($e_sz_str). Remaining: $(length(lru)) items ($r_sz_str). Capacity: $item_capacity items ($c_sz_str)."
	# end

	r_sz_str = _byte_size_string(lru.total_size)
	c_sz_str = _byte_size_string(mem_capacity)
	# set_text!(scheduler.lru_display_item[], "⋅ LRU: $(length(lru))/$item_capacity items ($r_sz_str/$c_sz_str)")
	if scheduler.lru_display_item[] !== nothing
		set_text!(scheduler.progress_display, scheduler.lru_display_item[], styled"{blue:⋅ LRU:} $(length(lru))/$item_capacity items ($r_sz_str/$c_sz_str)")
	end

	scheduler
end

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


fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep; external_call=false) for dep in deps)


function process_dependency!(scheduler, dep; @nospecialize(parent_f))
	dep.op === :call && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f, processing_errors_throw=false, external_call=false)
end
process_dependencies!(scheduler, deps; @nospecialize(parent_f)) =
	IdDict{Spec,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)




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



function ensure_work_task_is_running!(scheduler::Scheduler)
	if scheduler.work_task === nothing || istaskdone(scheduler.work_task) || istaskfailed(scheduler.work_task) || Base.get_world_counter() != scheduler.work_task_world_age
		empty!(scheduler.work_channel)
		empty!(scheduler.result_channel)
		scheduler.work_task_world_age = Base.get_world_counter()
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


# Hmm. Maybe better to not pass scheduler - seems like that might prevent GC of scheduler if restarted.
function work_runner(scheduler::Scheduler, work_channel::Channel{WorkUnion}, result_channel::Channel{Any})
	@info "Spawned work task"
	progress_display = scheduler.progress_display

	for work in work_channel # will exit when work_channel is closed
		progress_item = nothing
		sa = work.sa::SpecArgs

		local res
		try
			f = sa.f

			# NB: Deduplication and thus also Preprocessing are not thread-safe and is thus currently assumed to not happen in parallel
			if work isa WorkPreprocess
				progress_item = add_item!(progress_display, ProgressItem(styled"{blue:⋅ Preprocessing} " * ReproducibleJobs.styled_function_name(f)))
				res = f(sa.args...; sa.kwargs...)
				@assert res !== nothing "Preprocessing of $f returned nothing"
				remove_item!(progress_display, progress_item)
			elseif work isa WorkCompute
				progress_item = add_item!(progress_display, ProgressItem(styled"{blue:⋅ Running} " * ReproducibleJobs.styled_function_name(f)))

				v = _get_kwarg(sa, :__version, nothing)
				@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

				kwargs = Iterators.filter(p->!startswith(string(p[1]),"__"), sa.kwargs)
				res = f(sa.args...; kwargs...)
				@assert res !== nothing "Computation of $f returned nothing"
				remove_item!(progress_display, progress_item)
			elseif work isa WorkDeduplicateResult
				# TODO: Only show deduplication message if it takes time (>0.1s).
				progress_item = add_item!(progress_display, ProgressItem(styled"{blue:⋅ Deduplicating }" * ReproducibleJobs.styled_function_name(f); type=:pending))
				res = deduplicate!(scheduler.deduplicator, work.obj)
				remove_item!(progress_display, progress_item)
			end
		catch e
			exception_text = _short_exception_string(e)
			progress_item !== nothing && remove_item!(progress_display, progress_item, styled"{red:$exception_text}")
			if e isa InterruptException
				res = e
			else
				# TODO: Where to show error?
				# io = IOBuffer()
				# Base.showerror(IOContext(io, :color=>true), e)
				# message = String(take!(io))
				# @warn message

				# Do not show anything/much here, it will be shown later instead.
				bt = Base.catch_backtrace()
				res = ProcessingException(sa, e, stacktrace(bt))
			end
		end

		put!(result_channel, res)
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


preprocess(::Scheduler, err::Exception) = err

function preprocess(scheduler::Scheduler, sa::SpecArgs)
	res = process_work(scheduler, WorkPreprocess(sa))
	res = process_work(scheduler, WorkDeduplicateResult(sa, res))
end



compute(::Scheduler, err::Exception) = err

function compute(scheduler::Scheduler, sa::SpecArgs)
	res = process_work(scheduler, WorkCompute(sa))
	res = process_work(scheduler, WorkDeduplicateResult(sa, res))
end




function replace_dependencies(sa::SpecArgs, upstream::IdDict{Spec,Any})
	err = propagate_error(sa, values(upstream))
	err !== nothing && return err
	return map_args(x->get(upstream,x,nothing), sa)
end

function _fetch_and_compute!(scheduler, sa::SpecArgs, deps::Vector{Spec})
	fetched_deps = fetch_dependencies!(scheduler, deps)

	if !isempty(fetched_deps)
		sa = replace_dependencies(sa, fetched_deps)::Union{SpecArgs,ProcessingException,InterruptException}
	end
	res = compute(scheduler, sa)
	@assert !(res isa Spec)
	return res
end


function _fetch_and_compute_cached!(scheduler, sa::SpecArgs, deps::Vector{Spec})
	inner_spec = sa.args[1]::Spec
	inner_sa = get_sa(inner_spec)
	inner_deps = get_dependencies(inner_sa)
	@assert all(s->s.op === :call, inner_deps) # The outer call has enforced all inner specs to be calls has well.

	cache_get!(scheduler.cache, inner_sa) do
		_fetch_and_compute!(scheduler, inner_sa, inner_deps)
	end
end

# TODO: Simplify code
function _fetch_and_compute_sub!(scheduler, sa::SpecArgs, deps::Vector{Spec})
	@assert sa.f in (compoundresult_sub, compoundresult_keys)

	cached_sa = get_sa(sa.args[1]::Spec)
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
		# @info "Found cached CompoundResult ($(get_sa(cached_sa.args[1]).f))"
		cr = cached_sa.result
		cr isa Exception && return cr
		@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
		return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
	end

	w = cached_sa.weak_result
	if w !== NotValid()
		# @info "Attempting 2 ($(get_sa(cached_sa.args[1]).f))"

		# Attempt to reconstruct from weakly stored CompoundResult
		@assert w isa CompoundResult "Expected CompoundResult, got $(typeof(w))."
		sub === nothing && return get_keys(w)
		# sub === nothing && return (@info "2 success $sub ($(get_sa(cached_sa.args[1]).f))"; return get_keys(w))
		v = reconstruct_weak_rec(get_subresult(w, sub))
		v !== NotValid() && return v
		# v !== NotValid() && (@info "2 success $sub ($(get_sa(cached_sa.args[1]).f))"; return v)
		# @info "2 failed ($(get_sa(cached_sa.args[1]).f))"
		v !== NotValid() && return v
		# v !== NotValid() && (@info "2 success $sub ($(get_sa(cached_spec.args[1]).f))"; return v)
		# @info "2 failed ($(get_sa(cached_spec.args[1]).f))"
	end

	# 3.
	inner_sa = get_sa(cached_sa.args[1])
	# @info "Attempting 3 ($(get_sa(cached_sa.args[1]).f))"
	v = cache_try_get_compoundresult(scheduler.cache, inner_sa; sub, return_keys=sub===nothing)
	v !== NotValid() && return v
	# v !== NotValid() && (@info "3 success $sub ($(get_sa(cached_sa.args[1]).f))"; return v)
	# @info "3 failed ($(get_sa(cached_sa.args[1]).f))"

	# 4.
	# @info "Attempting 4 ($(get_sa(cached_sa.args[1]).f))"
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



function _process_once!(scheduler::Scheduler, sa::SpecArgs, deps::Vector{Spec})
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sa.f)

	if !isempty(forwarded_deps)
		sa = replace_dependencies(sa, forwarded_deps)::Union{SpecArgs,ProcessingException,InterruptException}
	end

	sa isa Exception && return sa

	if is_preprocessing(sa)
		preprocess(scheduler, sa)
	else
		sa = deduplicate!(scheduler.deduplicator, sa)
		Spec(sa, :call)
	end
end





# TODO: Move these somewhere else?
# These functions are actually never called. We just use them as singleton values to show that something is using the on-disk cache.
function compoundresult_sub end
function compoundresult_keys end
function get_cached end

function cached(spec::Spec, sub::Union{Nothing,String}=nothing; return_keys::Bool=false)
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
function process_once!(scheduler::Scheduler, sa::SpecArgs, op::Symbol; @nospecialize(parent_f))
	if parent_f !== nothing && op in (:forward,:prefetch)
		if !should_forward_child(parent_f, sa.f) # TODO: Avoid passing parent_f which can have many different types and just pass sufficient info to make this decision? Then we can get rid of @nospecialize...
			return (Spec(sa, op), true)
		end
	end

	deps = get_dependencies(sa)

	if !is_preprocessing(sa) && all(x->x.op === :call, deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		op === :forward && return (Spec(sa, :call), true)

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
		@assert !(res isa Spec)

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

	if res isa Spec
		return res, false
	else
		return res, true # forwarding returned a value, we are done
	end
end


function _reset_progress_display!(scheduler, sa::SpecArgs)
	empty!(scheduler.progress_display)
	add_item!(scheduler.progress_display, ProgressItem(styled"{blue:Scheduler: }" * ReproducibleJobs.styled_function_name(sa.f)))
	scheduler.lru_display_item[] = add_item!(scheduler.progress_display, ProgressItem(styled"{blue:LRU:}"; type=:text))
end


function process!(scheduler::Scheduler, sa::SpecArgs, op::Symbol; @nospecialize(parent_f=nothing), processing_errors_throw=true, external_call=true)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, sa)
	end
	evict_results!(scheduler; evict_all=false)

	while true
		res, done = process_once!(scheduler, sa, op; parent_f)
		# done && return res
		if done
			processing_errors_throw && res isa Exception && throw(res)
			return res
		end
		res::Spec
		sa = get_sa(res)
		# NB: Keep the op
	end
end


fetch!(scheduler::Scheduler, spec::Spec; kwargs...) = process!(scheduler, get_sa(spec), :fetch; kwargs...)
forward!(scheduler::Scheduler, spec::Spec; kwargs...) = process!(scheduler, get_sa(spec), :forward; kwargs...)
process!(scheduler::Scheduler, spec::Spec; kwargs...) = process!(scheduler, get_sa(spec), spec.op; kwargs...)


function forward_once!(scheduler::Scheduler, spec::Spec; @nospecialize(parent_f=nothing), processing_errors_throw=true, external_call=true)
	sa = get_sa(spec)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, sa)
	end
	evict_results!(scheduler; evict_all=false)
	res, _ = process_once!(scheduler, sa, :forward; parent_f)
	processing_errors_throw && res isa Exception && throw(res)
	res
end


fetch!(spec::Spec; kwargs...) = fetch!(get_scheduler(), spec; kwargs...)
forward!(spec::Spec; kwargs...) = forward!(get_scheduler(), spec; kwargs...)
forward_once!(spec::Spec; kwargs...) = forward_once!(get_scheduler(), spec; kwargs...)
process!(spec::Spec; kwargs...) = process!(get_scheduler(), spec; kwargs...)



# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	print(io, scheduler.lru)
	print(io,')')
end
