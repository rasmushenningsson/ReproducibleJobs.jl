struct WorkCompute
	spec::Spec
end
struct WorkPreprocess
	spec::Spec
end
struct WorkDeduplicateResult
	spec::Spec
	obj::Any
end
struct WorkCacheGet
	sr::SpecRun
	inner_res::Any
end
struct WorkSubGet
	sr::SpecRun # compoundresult_sub or compoundresult_keys sr
end

const WorkUnion = Union{WorkCompute, WorkPreprocess, WorkDeduplicateResult, WorkCacheGet, WorkSubGet}


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




function propagate_error(spec::Spec, vals)::Union{Nothing, ProcessingException}#, InterruptException}
	if any(x->x isa ProcessingException, vals)
		causes = filter!(x->x isa ProcessingException, collect(vals))
		return ProcessingException(spec, causes)
	else
		return nothing
	end
end

function set_result!(scheduler::Scheduler, sr::SpecRun, res)
	if !(res isa Exception) && !is_preprocessing(sr)
		lru_touch!(scheduler.lru, sr) do
			Base.summarysize(res)
		end
	end
	set_result!(sr, res)
end

function get_result!(scheduler::Scheduler, sr::SpecRun)
	res = get_result!(sr)
	if res !== NotValid() && !(res isa Exception) && !is_preprocessing(sr)
		lru_touch!(scheduler.lru, sr) do
			Base.summarysize(res)
		end
	end
	res
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
	# length(s) > n && (s = s[1:n-3]*"...")
	length(s) > n && (s = s[1:prevind(s,end,3)]*"...") # This version handles UTF8
	s
end


function work_run_single(scheduler, work::WorkUnion, result_channel::Channel)
	progress_display = scheduler.progress_display
	progress_item = nothing

	local spec::Spec
	local res
	try

		# NB: Deduplication and thus also Preprocessing are not thread-safe and is thus currently assumed to not happen in parallel
		if work isa WorkPreprocess
			spec = work.spec
			f = spec.f
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Preprocessing} " * ReproducibleJobs.styled_function_name(f)))
			res = f(spec.args...; spec.kwargs...)
			@assert res !== nothing "Preprocessing of $f returned nothing"
		elseif work isa WorkCompute
			spec = work.spec
			f = spec.f
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Running} " * ReproducibleJobs.styled_function_name(f)))

			v = _get_kwarg(spec, :__version, nothing)
			@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."

			kwargs = Iterators.filter(p->!startswith(string(p[1]),"__"), spec.kwargs)
			res = f(spec.args...; kwargs...)
			@assert res !== nothing "Computation of $f returned nothing"
		elseif work isa WorkDeduplicateResult
			spec = work.spec
			f = spec.f
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Deduplicating} " * ReproducibleJobs.styled_function_name(f); type=:pending))
			res = deduplicate!(scheduler.deduplicator, work.obj; transfer_ownership=true) # Since it is a result, we know that we own the data
		elseif work isa WorkCacheGet
			spec = work.sr.spec
			f = spec.args[1].f # This is the inner `f`
			action = work.inner_res === NotValid() ? "load"	: "save"
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Cache $action} " * ReproducibleJobs.styled_function_name(f)))
			res = cache_get!(scheduler.cache, work.sr) do
				work.inner_res # If we get here, the inner call was performed and the value replaced, so this is the result from the inner spec.
			end
		elseif work isa WorkSubGet
			spec = work.sr.spec
			cached_sr = get_sr(spec.args[1]::Job)
			f = cached_sr.spec.args[1].f # This is the inner `f`
			sub = work.sr.f === compoundresult_sub ? spec.args[2]::String : nothing
			progress_item = add_item!(progress_display, ProgressText(styled"{blue:⋅ Cache load} " * ReproducibleJobs.styled_function_name(f))) # TODO: print sub/keys
			res = cache_try_get_compoundresult(scheduler.cache, cached_sr; sub, return_keys=sub===nothing)
			@assert res !== NotValid() "Expected CompoundResult on disk but not found"
		end
		progress_item !== nothing && remove_item!(progress_display, progress_item)
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
		res = ProcessingException(spec, e, stacktrace(bt))
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

	# Temp. Better to add a print_display at the very end of the external call.
	print_display(progress_display)

	res
end


# preprocess(::Scheduler, err::Exception) = err

function preprocess(scheduler::Scheduler, spec::Spec)
	res = process_work(scheduler, WorkPreprocess(spec))
	res = process_work(scheduler, WorkDeduplicateResult(spec, res))
end



# compute(::Scheduler, err::Exception) = err

function compute(scheduler::Scheduler, spec::Spec)
	res = process_work(scheduler, WorkCompute(spec))
	res = process_work(scheduler, WorkDeduplicateResult(spec, res))
end


function process_get_cached(scheduler, sr::SpecRun, inner_res)
	process_work(scheduler, WorkCacheGet(sr, inner_res))
end

function process_sub_get(scheduler, sr::SpecRun, inner_cr)
	if inner_cr === NotValid()
		process_work(scheduler, WorkSubGet(sr))
	else
		inner_cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))
		sub = sr.f === compoundresult_sub ? sr.spec.args[2]::String : nothing
		sub === nothing ? get_keys(inner_cr) : get_subresult(inner_cr, sub)
	end
end




function replace_dependencies(spec::Spec, upstream::IdDict{Job,Any})
	err = propagate_error(spec, values(upstream))
	err !== nothing && return err
	return map_args(x->get(upstream,x,nothing), spec)
end




# TODO: Move these somewhere else?
# These functions are actually never called. We just use them as singleton values to show that something is using the on-disk cache.
function compoundresult_sub end
function compoundresult_keys end
function get_cached end

function cached(job::Job, sub::Union{Nothing,String}=nothing; return_keys::Bool=false)
	@assert sub==nothing || return_keys==false

	c = create_spec(get_cached, job; __version=v"1.0.0")
	if sub !== nothing
		create_spec(compoundresult_sub, c, sub; __version=v"0.0.1")
	elseif return_keys
		create_spec(compoundresult_keys, c; __version=v"0.0.1")
	else
		c
	end
end




function setup_dependency!(scheduler, sr::SpecRun{State}, call::Bool, dep::Job, curr::Job)
	# curr::Job = dep
	if call
		@assert curr.op == :call
		next = setup_processing!(scheduler, curr)
	else
		# stop before calling (but allow fetch/prefetch to call)
		next = curr

		override = dep.op === :fetch || (dep.op === :prefetch && !is_preprocessing(sr))
		while override || (curr.op !== :call && should_forward_child(sr.f, curr.f))
			# @show override, sr.f, curr.f, curr.op
			next = setup_processing!(scheduler, curr)
			next isa Job || break
			# @show override, sr.f, curr.f, curr.op, next.op
			curr = next # transfer op?? Nah. I don't think so.
		end
	end

	if next === NotValid() # we are waiting for an upstream spec to process
		s = curr.sr.state.x::Union{Waiting{State}, Processing{State}}
		push!(s.downstream, sr=>dep)
	end
	next
end


function update_dependency!(scheduler, sr::SpecRun{State}, dep::Job, res)
	@assert res !== NotValid()

	waiting = sr.state.x::Waiting
	waiting.upstream[dep] = res
	waiting.n_upstream_left[] -= 1
	waiting.n_upstream_left[] == 0 || return NotValid()

	if waiting.call || is_preprocessing(sr)
		push!(scheduler.processing_queue, sr)
		return NotValid()
	else
		# All deps forwarded — replace dep args with forwarded jobs, create new :call spec
		downstream = waiting.downstream
		spec_replaced = replace_dependencies(sr.spec, waiting.upstream)::Union{Spec,ProcessingException}
		if spec_replaced isa ProcessingException
			set_result!(scheduler, sr, spec_replaced)
			update_downstream!(scheduler, downstream, spec_replaced)
			return spec_replaced
		else
			sr_replaced = deduplicate!(scheduler.deduplicator, SpecRun(spec_replaced); transfer_ownership=true)
			new_job = Job(sr_replaced, :call)
			sr.state = state_next(new_job)
			update_downstream!(scheduler, downstream, new_job)
			return new_job
		end
	end
end


# WIP
# This function will do one of the following:
# 1. return the preprocessed spec/result if there is one cached
# 2. return the computed result if there is one cached
# 3. push the spec to the processing queue (if all dependencies are ready)
# 4. set it up to wait for dependencies to finish processing
# It may also recursively call setup_processing for the dependencies.
function setup_processing!(scheduler, job)
	sr, op = job.sr, job.op

	# Cached forwarding
	sr.state.x isa Next{State} && return sr.state.x.ref

	if is_preprocessing(sr)
		# Cached result
		res = get_result!(scheduler, sr)
		res !== NotValid() && return res # Early out for preprocessing specs - it **preprocessed** to a result
	end

	deps = get_dependencies(sr)
	ready_to_call = !is_preprocessing(sr) && all(x->x.op === :call, deps)

	op === :forward && ready_to_call && return Job(sr, :call) # We cannot forward any further (Hmm. Should we ever get here? I think we want to prevent this case at an earlier step.)

	if !is_preprocessing(sr)
		# Cached result
		res = get_result!(scheduler, sr)
		res !== NotValid() && return res # Early out for computing specs
	end

	sr.state.x isa Union{Waiting{State},Processing{State}} && return NotValid() # It has already been setup.

	@assert sr.state.x isa Initialized


	# Experimental handling of get_cached, compoundresult_sub, compoundresult_keys.
	# Further handling in process_step_new!().
	if ready_to_call
		if sr.f === get_cached
			if cache_haskey(scheduler.cache, sr) # TODO: Use inner spec as key instead
				empty!(deps) # Do not process the deps - we will load from disk!
			end
		elseif sr.f === compoundresult_sub || sr.f === compoundresult_keys
			cached_sr = get_sr(sr.spec.args[1]::Job)
			sub = sr.f === compoundresult_sub ? sr.spec.args[2]::String : nothing

			# 1. In-memory result of get_cached
			if cached_sr.state.x isa Result && cached_sr.state.x.result !== NotValid()
				cr = get_result!(scheduler, cached_sr) # will not reconstruct from weak since result !== NotValid()
				if cr isa Exception
					set_result!(scheduler, sr, cr)
					return cr
				end
				cr isa CompoundResult || throw(ArgumentError("Expected CompoundResult, got $(typeof(cr))"))
				res = sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
				set_result!(scheduler, sr, res)
				return res
			end

			# 2. Weak result of get_cached
			if cached_sr.state.x isa Result
				w = cached_sr.state.x.weak_result
				if w !== NotValid()
					w isa CompoundResult || throw(ArgumentError("Expected CompoundResult, got $(typeof(w))"))
					if sub === nothing
						res = get_keys(w)
						set_result!(scheduler, sr, res)
						return res
					end
					v = reconstruct_weak_rec(get_subresult(w, sub))
					if v !== NotValid()
						set_result!(scheduler, sr, v)
						return v
					end
				end
			end

			# 3. Disk partial load — WorkSubGet handles it in work_run_single
			if cache_haskey(scheduler.cache, cached_sr) # TODO: Use inner spec as key instead
				empty!(deps) # Do not process the deps - we will load from disk!
			end

			# 4. Fall through — process get_cached dep normally
		end
	end


	upstream = IdDict{Job,Any}()
	sr.state = state_waiting(upstream, length(deps), ready_to_call)

	for dep in deps
		next = setup_dependency!(scheduler, sr, ready_to_call, dep, dep)
		if next !== NotValid()
			res = update_dependency!(scheduler, sr, dep, next)
			res !== NotValid() && return res
		end
	end

	isempty(deps) && push!(scheduler.processing_queue, sr) # no deps — ready immediately
	return NotValid()
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






# function update_downstream!(scheduler::Scheduler, downstream::Vector{Pair{SpecRun{State},Job}}, res)
# 	@assert res !== NotValid()

# 	for (sr, dep) in downstream
# 		waiting = sr.state.x::Waiting{State}

# 		if res isa Job
# 			# If res is a forwarded job, continue following the chain before updating
# 			next = setup_dependency!(scheduler, sr, waiting.call, res)
# 			next !== NotValid() && update_dependency!(scheduler, sr, dep, next)
# 		else
# 			update_dependency!(scheduler, sr, dep, res)
# 		end
# 	end
# end

function update_downstream!(scheduler::Scheduler, downstream::Vector{Pair{Union{SpecRun{State},Function},Job}}, res)
	@assert res !== NotValid()

	for (owner, dep) in downstream
		if owner isa SpecRun{State}
			sr = owner::SpecRun{State}
			waiting = sr.state.x::Waiting{State}

			if res isa Job
				# If res is a forwarded job, continue following the chain before updating
				# next = setup_dependency!(scheduler, sr, waiting.call, res)
				next = setup_dependency!(scheduler, sr, waiting.call, dep, res)
				next !== NotValid() && update_dependency!(scheduler, sr, dep, next)
			else
				update_dependency!(scheduler, sr, dep, res)
			end
		else#if owner isa Function
			f = owner
			f(dep, res)
		end
	end
end



function process_step_new!(scheduler::Scheduler, sr::SpecRun)
	waiting = sr.state.x::Waiting{State}
	@assert waiting.n_upstream_left[] == 0

	if isempty(waiting.upstream)
		spec_replaced = sr.spec
	else
		spec_replaced = replace_dependencies(sr.spec, waiting.upstream)::Union{Spec,ProcessingException}
	end
	spec_replaced isa Exception && return spec_replaced

	downstream = waiting.downstream
	sr.state = state_processing(downstream)
	if is_preprocessing(sr)
		res = preprocess(scheduler, spec_replaced)
		if res isa Job
			sr.state = state_next(res)
		else
			set_result!(scheduler, sr, res) # Preprocessing yielded a result, we are done.
		end
		update_downstream!(scheduler, downstream, res)
		return res
	else
		if sr.f === get_cached
			inner_res = isempty(waiting.upstream) ? NotValid() : spec_replaced.args[1]
			res = process_get_cached(scheduler, sr, inner_res)
		elseif sr.f === compoundresult_sub || sr.f === compoundresult_keys
			inner_cr = isempty(waiting.upstream) ? NotValid() : spec_replaced.args[1]
			res = process_sub_get(scheduler, sr, inner_cr)
		else
			res = compute(scheduler, spec_replaced)
		end

		# res = compute(scheduler, spec_replaced)
		# @assert !(res isa CompoundResult) # Is this a good place to check? Maybe should be ensured earlier. # Probably not correct after the refactoring.
		@assert !(res isa Job)

		set_result!(scheduler, sr, res)
		update_downstream!(scheduler, downstream, res)
		return res
	end
end

function process_new!(scheduler::Scheduler, job::Job; processing_errors_throw=true, external_call=true, once=false)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, job.sr)
	end
	evict_results!(scheduler; evict_all=false)
	_update_gc_display!(scheduler)

	op = job.op

	# TODO: simplify code?
	while true
		res = setup_processing!(scheduler, job)

		new_res = Ref{Any}(nothing)

		if res === NotValid()
			s = job.sr.state.x::Union{Waiting{State}, Processing{State}}
			push!(s.downstream, ((j,r)->new_res[] = r)=>job) # register callback!

			while !isempty(scheduler.processing_queue)
				curr_sr = pop!(scheduler.processing_queue) # LIFO
				process_step_new!(scheduler, curr_sr)
				# Consider early out on error?
				# x = process_step_new!(scheduler, curr_sr)
				# processing_errors_throw && x isa Exception && throw(res)
			end

			# NB: The callback has now modified new_res
			res = new_res[]
			@assert res !== NotValid()
		end

		res isa Exception && throw(res)

		if res isa Job
			once && return res # Only take one step
			op in (:forward,:prefetch) && res.op === :call && return res
			job = transfer_op(job, res) # continue processing
		else
			return res # result
		end
	end
end

fetch_new!(scheduler::Scheduler, job::Job; kwargs...) = process_new!(scheduler, Job(get_sr(job), :fetch); kwargs...)
forward_new!(scheduler::Scheduler, job::Job; kwargs...) = process_new!(scheduler, Job(get_sr(job), :forward); kwargs...)
forward_once_new!(scheduler::Scheduler, job::Job; kwargs...) = process_new!(scheduler, Job(get_sr(job), :forward); kwargs..., once=true)

fetch_new!(job::Job; kwargs...) = fetch_new!(get_scheduler(), job; kwargs...)
forward_new!(job::Job; kwargs...) = forward_new!(get_scheduler(), job; kwargs...)
forward_once_new!(job::Job; kwargs...) = forward_once_new!(get_scheduler(), job; kwargs...)





# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	print(io, scheduler.lru)
	print(io,')')
end
