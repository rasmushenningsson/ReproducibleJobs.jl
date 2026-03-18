# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{SpecArgs,H} # spec -> forwarded spec or result

	lru::LRUCache{SpecArgs,Any} # To prevent GC of most recently used results
end
Scheduler(cache::Cache{SpecArgs,H}) where H = Scheduler{H}(cache.deduplicator, cache, LRUCache{SpecArgs,Any}())
Scheduler(deduplicator::Deduplicator{H}; kwargs...) where H = Scheduler(Cache(SpecArgs, deduplicator; kwargs...))
# Scheduler() = Scheduler(default_deduplicator())
Scheduler(; kwargs...) = Scheduler(Deduplicator(); kwargs...)


function Base.empty!(scheduler::Scheduler)
	empty!(scheduler.deduplicator)
	# empty!(scheduler.cache)
	empty!(scheduler.lru)
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


function _fetch_and_compute_cached!(scheduler, sa::SpecArgs, deps::Vector{Spec})
	inner_spec = sa.args[1]::Spec
	inner_sa = inner_spec.sa
	inner_deps = get_dependencies(inner_sa)
	@assert all(s->s.op === Call(), inner_deps) # The outer Call has enforced all inner `op`s to be called has well.

	cache_get!(scheduler.cache, inner_sa) do
		_fetch_and_compute!(scheduler, inner_sa, inner_deps)
	end
end
function _fetch_and_compute_sub!(scheduler, sa::SpecArgs, deps::Vector{Spec})
	@assert sa.f in (compoundresult_sub, compoundresult_keys)

	cached_spec = sa.args[1]::Spec
	cached_sa = cached_spec.sa
	@assert cached_sa.f == get_cached
	cached_deps = get_dependencies(cached_sa)
	@assert all(s->s.op === Call(), cached_deps) # The outer Call has enforced all sub `op`s to be called has well.

	# TODO: Try in this order
	# 0. (Already done) Is it cached and still valid in sa.result.
	# 1. Is the cached_sa result still valid? Then return subresult from that.
	# 2. Is the cached_sa cached to disk? Then load the subresult (only) from disk.
	# 3. Compute compoundresult and return sub.

	if sa.f == compoundresult_sub
		sub = sa.args[2]::String
	else #if sa.f == compoundresult_keys
		sub = nothing
	end


	# TODO: Put part of this in a helper function, get_result?, in spec.jl?
	# 1.
	if cached_sa.result !== NotValid()
		@info "Attempting 1 ($(cached_sa.args[1].sa.f))"
		# Attempt to reconstruct from weakly stored reference
		cr = cached_sa.result
		@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
		# sub === nothing && return get_keys(cr)
		sub === nothing && return (@info "1 success $sub ($(cached_sa.args[1].sa.f))"; return get_keys(cr))
		v = reconstruct_weak_rec(get_subresult(cr, sub))
		# v !== NotValid() && return v
		v !== NotValid() && (@info "1 success $sub ($(cached_sa.args[1].sa.f))"; return v)
		@info "1 failed ($(cached_sa.args[1].sa.f))"
	end

	# 2.
	inner_sa = cached_sa.args[1].sa
	@info "Attempting 2 ($(cached_sa.args[1].sa.f))"
	v = cache_try_get_compoundresult(scheduler.cache, inner_sa; sub, return_keys=sub===nothing)
	# v !== NotValid() && return v
	v !== NotValid() && (@info "2 success $sub ($(cached_sa.args[1].sa.f))"; return v)
	@info "2 failed ($(cached_sa.args[1].sa.f))"

	# 3.
	@info "Attempting 3 ($(cached_sa.args[1].sa.f))"
	cr = get_result!(cached_sa) do # This is to ensure cached_sa.result gets set, maybe use set_result! instead? Because we should never reach here if cached_sa.result !== nothing.
		_fetch_and_compute_cached!(scheduler, cached_sa, cached_deps)
	end
	cr isa Exception && return cr
	cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))

	lru_touch!(scheduler.lru, inner_sa, cr)

	# # Experimental version - only insert in the LRU if it was deconstructed!
	# # TODO: We want to improve this condition so that we check if the deconstructed result contains any weak refs, and if it does, put it in the LRU.
	# if cr !== cached_sa.result
	# 	lru_touch!(scheduler.lru, inner_sa, cr)
	# end

	return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
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
function process_once!(scheduler::Scheduler, sa::SpecArgs, op::T; parent_f) where T
	# Early out, we don't need to consider dependencies for this
	if parent_f !== nothing && T <: Union{Forward,Prefetch}
		if !should_forward_child(parent_f, sa.f)
			return Spec(sa, op), true # Keep Forward/Prefetch op
		end
	end

	# # DEBUG
	# h = lookup_hash(scheduler.deduplicator, sa)
	# @info "Processing $(sa.f) ($(hash_string(h)[1:6]), n=$(processing_count(h)))"


	deps = get_dependencies(sa)

	if !is_preprocessing(sa) && all(s->s.op === Call(), deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		T <: Forward && return (Spec(sa, Call()), true)


		# New
		# TODO: Simplify code
		res = get_result!(sa) do
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

		# lru
		lru_touch!(scheduler.lru, sa, res)

		# # Experimental version - only insert in the LRU if it was deconstructed!
		# # TODO: We want to improve this condition so that we check if the deconstructed result contains any weak refs, and if it does, put it in the LRU.
		# if res !== sa.result
		# 	lru_touch!(scheduler.lru, sa, res)
		# end

		return res, true
	end

	res = get_next!(sa) do
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
