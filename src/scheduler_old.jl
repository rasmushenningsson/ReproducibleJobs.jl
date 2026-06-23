state_waiting() = State(Waiting{State}([],IdDict{Job,Any}(), Ref(0), false)) # DUMMY USED DURING REFACTORING - TODO: Remove
state_processing() = State(Processing{State}([])) # DUMMY USED DURING REFACTORING - TODO: Remove



fetch_dependencies!(scheduler, deps) = IdDict{Job,Any}(dep=>fetch!(scheduler, dep; external_call=false) for dep in deps)

function process_dependency!(scheduler, dep; @nospecialize(parent_f))
	dep.op === :call && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f, processing_errors_throw=false, external_call=false)
end
process_dependencies!(scheduler, deps; @nospecialize(parent_f)) =
	IdDict{Job,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)


function _fetch_and_compute!(scheduler, sr::SpecRun, deps::Vector{Job})
	# TODO: Check that sr.state is as expected?
	sr.state = state_waiting()
	fetched_deps = fetch_dependencies!(scheduler, deps)

	if isempty(fetched_deps)
		spec_replaced = sr.spec
	else
		spec_replaced = replace_dependencies(sr.spec, fetched_deps)::Union{Spec,ProcessingException,InterruptException}
	end
	sr.state = state_processing()
	res = compute(scheduler, spec_replaced)
	@assert !(res isa Job)
	return res
end


function _fetch_and_compute_cached!(scheduler, sr::SpecRun, deps::Vector{Job})
	inner_job = sr.args[1]::Job
	inner_sr = get_sr(inner_job)
	inner_deps = get_dependencies(inner_sr)
	@assert all(s->s.op === :call, inner_deps) # The outer call has enforced all inner specs to be calls has well.

	sr.state = state_waiting()
	cache_get!(scheduler.cache, inner_sr) do
		_fetch_and_compute!(scheduler, inner_sr, inner_deps)
	end
end

# TODO: Simplify code
function _fetch_and_compute_sub!(scheduler, sr::SpecRun, deps::Vector{Job})
	@assert sr.f in (compoundresult_sub, compoundresult_keys)

	cached_sr = get_sr(sr.args[1]::Job)
	@assert cached_sr.f == get_cached
	cached_deps = get_dependencies(cached_sr)
	@assert all(s->s.op === :call, cached_deps) # The outer call has enforced all sub-specs to be calls has well.

	sr.state = state_waiting()

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


	if cached_sr.state.x isa Result
		# 1.
		if cached_sr.state.x.result !== NotValid()
			cr = cached_sr.state.x.result
			cr isa Exception && return cr
			@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
			return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
		end

		# 2.
		w = cached_sr.state.x.weak_result
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



function _process_once!(scheduler::Scheduler, sr::SpecRun, deps::Vector{Job})
	sr.state = state_waiting()
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sr.f)

	if isempty(forwarded_deps)
		spec_replaced = sr.spec
	else
		spec_replaced = replace_dependencies(sr.spec, forwarded_deps)::Union{Spec,ProcessingException,InterruptException}
	end

	spec_replaced isa Exception && return spec_replaced

	if is_preprocessing(spec_replaced)
		sr.state = state_processing()
		preprocess(scheduler, spec_replaced)
	else
		sr_replaced = deduplicate!(scheduler.deduplicator, SpecRun(spec_replaced))
		Job(sr_replaced, :call)
	end
end






# Return tuple with result and Bool telling if it's done (TODO: Make code more clear)
function process_once!(scheduler::Scheduler, sr::SpecRun{State}, op::Symbol)
	deps = get_dependencies(sr)

	if !is_preprocessing(sr) && all(x->x.op === :call, deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		op === :forward && return (Job(sr, :call), true)

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
		@assert !(res isa Job)

		lru_touch!(scheduler.lru, sr) do
			Base.summarysize(res)
		end

		set_result!(sr, res)
		return res, true
	end

	# Cached forwarding
	sr.state.x isa Next{State} && return (sr.state.x.ref, false)

	# Cached result
	res = get_result!(sr)
	res !== NotValid() && return (res, true)

	# Preprocess
	res = _process_once!(scheduler, sr, deps)
	if res isa Job
		sr.state = state_next(res)
		return res, false # Still forwarding, not done.
	end

	set_result!(sr, res) # Preprocessing yielded a result, we are done.
	return res, true
end



# TODO: Avoid passing parent_f which can have many different types and just pass sufficient info to make this decision? Then we can get rid of @nospecialize...
function process_old!(scheduler::Scheduler, sr::SpecRun, op::Symbol; @nospecialize(parent_f=nothing), processing_errors_throw=true, external_call=true)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, sr)
	end
	evict_results!(scheduler; evict_all=false)
	_update_gc_display!(scheduler)

	while true
		if parent_f !== nothing && op in (:forward,:prefetch) && !should_forward_child(parent_f, sr.f)
			external_call && print_display(scheduler.progress_display; final=true)
			return Job(sr, op) # processing done, we shouldn't forward anymore
		end

		res, done = process_once!(scheduler, sr, op)
		# done && return res
		if done
			external_call && print_display(scheduler.progress_display; final=true)
			processing_errors_throw && res isa Exception && throw(res)
			return res
		end
		res::Job
		sr = get_sr(res)
		# NB: Keep the op
	end
end




fetch_old!(scheduler::Scheduler, job::Job; kwargs...) = process_old!(scheduler, get_sr(job), :fetch; kwargs...)
forward_old!(scheduler::Scheduler, job::Job; kwargs...) = process_old!(scheduler, get_sr(job), :forward; kwargs...)
process_old!(scheduler::Scheduler, job::Job; kwargs...) = process_old!(scheduler, get_sr(job), job.op; kwargs...)


function forward_once_old!(scheduler::Scheduler, job::Job; processing_errors_throw=true, external_call=true)
	sr = get_sr(job)
	if external_call
		ensure_work_task_is_running!(scheduler)
		_reset_progress_display!(scheduler, sr)
	end
	evict_results!(scheduler; evict_all=false)
	_update_gc_display!(scheduler)
	res, _ = process_once!(scheduler, sr, :forward)
	external_call && print_display(scheduler.progress_display; final=true)
	processing_errors_throw && res isa Exception && throw(res)
	res
end


fetch_old!(job::Job; kwargs...) = fetch_old!(get_scheduler(), job; kwargs...)
forward_old!(job::Job; kwargs...) = forward_old!(get_scheduler(), job; kwargs...)
forward_once_old!(job::Job; kwargs...) = forward_once_old!(get_scheduler(), job; kwargs...)
process_old!(job::Job; kwargs...) = process_old!(get_scheduler(), job; kwargs...)


