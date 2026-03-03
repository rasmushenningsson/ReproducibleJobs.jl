# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler{H}
	deduplicator::Deduplicator{H}

	# forwarded::Dict{ReadOnly{SpecArgs}, Any} # Maps a spec to what it becomes after forwarding one step - either a Spec or a value (Any), but the former is way more common, maybe wrap in a union type?
	# results::Dict{ReadOnly{SpecArgs},Any} # spec -> result

	cache::Cache{SpecArgs,H} # spec -> forwarded spec or result
end
# Scheduler() = Scheduler(Dict{ReadOnly{SpecArgs}, ReadOnly{SpecArgs}}(), Dict{Tuple{ReadOnly{SpecArgs},Vector{String}},Any}())
Scheduler(cache::Cache{SpecArgs,H}) where H = Scheduler{H}(cache.deduplicator, cache)
Scheduler(deduplicator::Deduplicator{H}) where H = Scheduler(Cache(SpecArgs, deduplicator))
Scheduler() = Scheduler(default_deduplicator())


function Base.empty!(scheduler::Scheduler)
	empty!(scheduler.deduplicator)
	empty!(scheduler.cache)
	scheduler
end

let scheduler_singleton = Scheduler()
	global default_scheduler() = scheduler_singleton
end




# _arg_replacer(upstream) = Base.Fix2(_arg_replacer, upstream)
# _arg_replacer(x, upstream) = get(upstream, x, x) # replaces (pre)fetched specs by the value, and leaves everything else in place

# _unwrap_value(upstream) = Base.Fix2(_unwrap_value, upstream)
# _unwrap_value() = _unwrap_value(IdDict{Spec,Any}())

# function _unwrap_value(x, upstream)
# 	x isa Spec && return copy_nested(_unwrap_value(), upstream[x]) # Needed to handle e.g. a result which is a vector of `ReadOnly`s
# 	# x isa ReadOnly{<:Array} && return ReadOnlyArray(x.value) # TODO: Should we add this?
# 	x isa ReadOnly && return x.value
# 	x
# end


fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep) for dep in deps)



function process_dependency!(scheduler, dep; parent_f)
	dep.op === Call() && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep; parent_f)
end
process_dependencies!(scheduler, deps; parent_f) =
	IdDict{Spec,Any}(dep=>process_dependency!(scheduler, dep; parent_f) for dep in deps)





# function deduplicate_result(res)
# 	if res isa Spec
# 		res
# 	elseif res isa Managed
# 		# By returning a Managed result, the computing function takes responsibility of the contents, otherwise we need to standardize
# 		res = res.x
# 	elseif res isa CompoundResult
# 		CompoundResult(Pair{String,Any}[k=>deduplicate_result(v) for (k,v) in res.children])
# 	else
# 		f = deduplicate_leaves(default_deduplicator()) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
# 		copy_nested(f, res)
# 	end
# end


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

		# res = deduplicate_result(res) # needed because forwarding can return a value

		# TODO: use deduplicator in scheduler instead
		res = deduplicate!(default_deduplicator(), res) # needed because forwarding can return a value

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

	return replace_dependencies(upstream, sa)

	# replacer = _arg_replacer(upstream)

	# args = Any[copy_nested(replacer, a) for a in sa.args]
	# kwargs = Pair{Symbol,Any}[k=>copy_nested(replacer,v) for (k,v) in sa.kwargs]

	# sa_forwarded = SpecArgs(sa.f, args, kwargs)
	# return sa_forwarded
end


function compute(sa::SpecArgs, upstream::IdDict{Spec,Any})
	f = sa.f
	try
		@info "Running $f"
		err = propagate_error(sa, values(upstream))
		err !== nothing && return err

		v = _get_kwarg(sa, :__version, nothing)
		@assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs."
		# @assert v !== nothing "__version kwarg must be provided for all (non-preprocessing) specs. Missing for $f."

		# unwrapper = _unwrap_value(upstream)
		# args = (copy_nested(unwrapper, a) for a in sa.args)
		# kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in sa.kwargs if !startswith(string(k),"__"))

		sa_replaced = replace_dependencies(upstream, sa)
		args = sa_replaced.args
		kwargs = sa_replaced.kwargs

		# TODO: We can rewrite this more nicely now that kwargs is a NamedTuple
		# kwargs = (k=>v for (k,v) in sa.kwargs if !startswith(string(k),"__")) # TODO: Find a better way to get rid of __ kwargs?
		# kwargs = (k=>v for (k,v) in pairs(sa.kwargs) if !startswith(string(k),"__")) # TODO: Find a better way to get rid of __ kwargs?

		# NamedTuple version
		kwargs = NamedTuple{filter(k->!startswith(string(k),"__"), keys(kwargs))}(kwargs)


		res = f(args...; kwargs...)
		@assert res !== nothing "Computation of $f returned nothing"

		# res = deduplicate_result(res)

		# TODO: use deduplicator in scheduler instead
		res = deduplicate!(default_deduplicator(), res)

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
	res
end


function _process_once!(scheduler::Scheduler, sa::SpecArgs, deps::Vector{Spec})
	forwarded_deps = process_dependencies!(scheduler, deps; parent_f=sa.f)
	if !isempty(forwarded_deps)
		sa = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
	end

	if is_preprocessing(sa)
		preprocess(sa)
	else
		sa isa ProcessingException && return sa

		# TODO: use deduplicator in scheduler instead
		sa = deduplicate!(default_deduplicator(), sa)
		Spec(sa, Call())

		# ro_forwarded = default_deduplicator()(sa) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		# Spec(ro_forwarded, Call())
	end
end






# TODO: Move these somewhere else?
function get_cached end # `get_cached` is actually never called. We just use it as singleton value to show that something is using the on-disk cache.

# Use `sub` to retrieve parts of `CompoundResult`s
function cached(spec, sub::String...; return_keys=false)
	extra_kwargs = (return_keys ? (; return_keys) : (;)) # only pass kwarg if set to true
	create_spec(get_cached, spec, sub...; extra_kwargs..., __version=v"1.0.0")
end



# # Helper function for recreating the Specs for retrieving individual parts of a CompoundResult
# _cached_rewrap(ro, sub; kwargs...) = cached(Spec(ro, Call()), sub...; kwargs...).ro

# function _insert_partial_results!(scheduler, ro, cr::CompoundResult, curr_sub=String[])
# 	# Insert keys as their own result
# 	scheduler.results[_cached_rewrap(ro,curr_sub; return_keys=true)] = first.(cr.children)
# 	for (k,v) in cr.children
# 		_insert_partial_results!(scheduler, ro, v, vcat(curr_sub, k))
# 	end
# end
# _insert_partial_results!(scheduler, ro, res, curr_sub) =
# 	scheduler.results[_cached_rewrap(ro,curr_sub)] = res





# function cached_call!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, deps::Vector{Spec}; sub::Union{Nothing, Vector{String}}, return_keys::Bool)
# 	@assert all(x->x.op === Call(), deps) # Probably remove, it is already checked in process_once!
# 	sa = ro.value
# 	@assert sa.f !== get_cached # Probably remove, it is already checked in process_once!

# 	key = get_cache_key(ro)

# 	# Load from cache if it's already in there
# 	res = cache_load(key, sub; return_keys)
# 	res !== nothing && return res

# 	# Compute
# 	res = _fetch_and_compute!(scheduler, sa, deps)

# 	# Store in on-disk cache
# 	cache_save(key, res)

# 	if res isa CompoundResult
# 		# TODO: Figure out a better place to do this (we are currently inside a get!(scheduler.results, ro) call, so it works, but it is a bit awkward)
# 		# Insert all parts of the result into the in-RAM cache
# 		_insert_partial_results!(scheduler, ro, res)

# 		# sub === nothing && throw(ArgumentError("Cannot retrieve CompoundResult directly, sub-result must be specified."))

# 		# But only return the sub we asked for
# 		return get_subresult(res, sub; return_keys)
# 	elseif !(res isa ProcessingException)
# 		return_keys && throw(ArgumentError("return_keys can only be used on CompoundResults."))
# 		sub === nothing || throw(ArgumentError("Cannot retrieve sub-result unless the result is a CompoundResult (tried to retrieve: $sub)."))
# 	end
# 	return res
# end

# # Rename? Remove?
# function standard_call!(scheduler::Scheduler, sa::SpecArgs, deps::Vector{Spec})
# 	@assert all(x->x.op === Call(), deps) # Probably remove, it is already checked in process_once!

# 	@info "Bypassing on-disk cache"
# 	res = _fetch_and_compute!(scheduler, sa, deps)
# 	@assert !(res isa CompoundResult) # We only support CompoundResults when using the on-disk cache
# 	return res
# end



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
			# sub = length(sa.args)==1 ? nothing : collect(String, @view(sa.args[2:end]))
			sub = length(sa.args)==1 ? nothing : only(@view(sa.args[2:end])) # we only support one level atm
			return_keys = _get_kwarg(sa, :return_keys, false)

			# TODO: Cleanup and simplify code
			if sub !== nothing || return_keys
				res = cache_get_subresult!(cache, inner_sa; use_disk=true, sub, return_keys) do
					_fetch_and_compute!(scheduler, inner_sa, inner_deps)
				end
			else
				res = cache_get!(scheduler.cache, inner_sa; use_disk=true) do
					_fetch_and_compute!(scheduler, inner_sa, inner_deps)
				end
			end
		else
			res = cache_get!(scheduler.cache, sa; use_disk=false) do
				# standard_call!(scheduler, sa, deps)
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
