# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler{H}
	deduplicator::Deduplicator{H}

	cache::Cache{SpecArgs,H} # spec -> result stored on disk

	lru::LRUCache{SpecArgs} # To prevent GC of most recently used results
end
Scheduler(cache::Cache{SpecArgs,H}) where H = Scheduler{H}(cache.deduplicator, cache, LRUCache{SpecArgs}())
Scheduler(deduplicator::Deduplicator{H}; kwargs...) where H = Scheduler(Cache(SpecArgs, deduplicator; kwargs...))
# Scheduler() = Scheduler(default_deduplicator())
Scheduler(; kwargs...) = Scheduler(Deduplicator(); kwargs...)

function evict_results!(scheduler::Scheduler; evict_all=true, max_n::Int=100)
	length(scheduler.lru)>max_n && @info "Evicting $(length(scheduler.lru)-max_n) results."

	while !isempty(scheduler.lru) && (evict_all || length(scheduler.lru)>max_n)
		sa = lru_pop!(scheduler.lru)
		sa !== nothing && empty_result!(sa)
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
	process!(scheduler, dep; parent_f)
end
process_dependencies!(scheduler, deps; parent_f) =
	IdDict{SpecUnion,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)




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

function replace_forwarded(sa::SpecArgs, upstream::IdDict{<:SpecUnion,Any})
	err = propagate_error(sa, values(upstream))
	err !== nothing && return err
	return map_args(x->get(upstream,x,nothing), sa)
end


function compute(scheduler::Scheduler, sa::SpecArgs, upstream::IdDict{<:SpecUnion,Any})
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


function _fetch_and_compute!(scheduler, sa::SpecArgs, deps::Vector{<:SpecUnion})
	deps = fetch_dependencies!(scheduler, deps)
	res = compute(scheduler, sa, deps)
	@assert !(res isa SpecUnion)
	res
end


function _fetch_and_compute_cached!(scheduler, sa::SpecArgs, deps::Vector{<:SpecUnion})
	inner_spec = sa.args[1]::SpecUnion
	inner_sa = get_sa(inner_spec)
	inner_deps = get_dependencies(inner_sa)
	@assert all(s->s isa Call, inner_deps) # The outer Call has enforced all inner specs to be Calls has well.

	cache_get!(scheduler.cache, inner_sa) do
		_fetch_and_compute!(scheduler, inner_sa, inner_deps)
	end
end

# TODO: Simplify code
function _fetch_and_compute_sub!(scheduler, sa::SpecArgs, deps::Vector{<:SpecUnion})
	@assert sa.f in (compoundresult_sub, compoundresult_keys)

	cached_spec = sa.args[1]::SpecUnion
	cached_sa = get_sa(cached_spec)
	@assert cached_sa.f == get_cached
	cached_deps = get_dependencies(cached_sa)
	@assert all(s->s isa Call, cached_deps) # The outer Call has enforced all sub specs to be Calls has well.

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
		@info "Found cached CompoundResult ($(cached_sa.args[1].sa.f))"
		cr = cached_sa.result
		@assert cr isa CompoundResult "Expected CompoundResult, got $(typeof(cr))."
		return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
	end

	w = cached_sa.weak_result
	if w !== NotValid()
		@info "Attempting 2 ($(cached_sa.args[1].sa.f))"

		# Attempt to reconstruct from weakly stored CompoundResult
		@assert w isa CompoundResult "Expected CompoundResult, got $(typeof(w))."
		# sub === nothing && return get_keys(w)
		sub === nothing && return (@info "2 success $sub ($(cached_sa.args[1].sa.f))"; return get_keys(w))
		v = reconstruct_weak_rec(get_subresult(w, sub))
		# v !== NotValid() && return v
		v !== NotValid() && (@info "2 success $sub ($(cached_sa.args[1].sa.f))"; return v)
		@info "2 failed ($(cached_sa.args[1].sa.f))"
	end

	# 3.
	inner_sa = cached_sa.args[1].sa
	@info "Attempting 3 ($(cached_sa.args[1].sa.f))"
	v = cache_try_get_compoundresult(scheduler.cache, inner_sa; sub, return_keys=sub===nothing)
	# v !== NotValid() && return v
	v !== NotValid() && (@info "3 success $sub ($(cached_sa.args[1].sa.f))"; return v)
	@info "3 failed ($(cached_sa.args[1].sa.f))"

	# 4.
	@info "Attempting 4 ($(cached_sa.args[1].sa.f))"
	cr = get_result!(cached_sa) do # This is to ensure cached_sa.result gets set, maybe use set_result! instead? Because we should never reach here if cached_sa.result !== nothing.
		_fetch_and_compute_cached!(scheduler, cached_sa, cached_deps)
	end
	cr isa Exception && return cr
	cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))

	lru_touch!(scheduler.lru, inner_sa)

	return sub === nothing ? get_keys(cr) : get_subresult(cr, sub)
end



function _process_once!(scheduler::Scheduler, sa::SpecArgs, deps::Vector{<:SpecUnion})
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sa.f)

	if !isempty(forwarded_deps)
		sa = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
	end

	if is_preprocessing(sa)
		preprocess(scheduler, sa)
	else
		sa isa ProcessingException && return sa

		sa = deduplicate!(scheduler.deduplicator, sa)
		Call(sa)
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
function process_once!(scheduler::Scheduler, spec::T; parent_f) where T<:SpecUnion
	# Early out, we don't need to consider dependencies for this
	if parent_f !== nothing && T <: Union{SpecArgs,Prefetch}
		if !should_forward_child(parent_f, spec.f)
			return spec, true
		end
	end

	sa = get_sa(spec)

	deps = get_dependencies(sa)

	if !is_preprocessing(sa) && all(s->s isa Call, deps)
		# ready to call

		# Stop if we are forwarding, nothing left to do
		T===SpecArgs && return (Call(sa), true)


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
		@assert !(res isa SpecUnion)

		lru_touch!(scheduler.lru, sa)

		return res, true
	end

	res = get_next!(sa) do
		# # DEBUG
		# h = lookup_hash(scheduler.deduplicator, sa)
		# @info "Preprocessing $(sa.f) ($(hash_string(h)[1:6]), n=$(processing_count(h)))"

		_process_once!(scheduler, sa, deps)
	end

	if res isa SpecUnion
		return res, false
	else
		return res, true # forwarding returned a value, we are done
	end
end


function process!(scheduler::Scheduler, spec::T; parent_f=nothing) where T<:SpecUnion
	evict_results!(scheduler; evict_all=false)

	while true
		res, done = process_once!(scheduler, spec; parent_f)
		done && return res
		res::SpecUnion
		spec = transfer_op(spec, res)
	end
end


fetch!(scheduler::Scheduler, s::SpecUnion; kwargs...) = process!(scheduler, fetched(s); kwargs...)
forward!(scheduler::Scheduler, s::SpecUnion; kwargs...) = process!(scheduler, get_sa(s); kwargs...) # strip Wrapper to get forwarding

function forward_once!(scheduler::Scheduler, s::SpecUnion; parent_f=nothing)
	res, _ = process_once!(scheduler, get_sa(s); parent_f) # strip Wrapper to get forwarding
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
