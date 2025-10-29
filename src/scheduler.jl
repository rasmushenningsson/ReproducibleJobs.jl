# This is a simple single-threaded scheduler.
# It is expected to change name later.
# And maybe not be the default.

struct Scheduler
	forwarded::Dict{ReadOnly{SpecArgs}, Any} # Maps a spec to what it becomes after forwarding one step - either a Spec or a value (Any), but the former is way more common, maybe wrap in a union type?
	results::Dict{ReadOnly{SpecArgs},Any} # spec -> result
end
Scheduler() = Scheduler(Dict{ReadOnly{SpecArgs}, ReadOnly{SpecArgs}}(), Dict{Tuple{ReadOnly{SpecArgs},Vector{String}},Any}())


function Base.empty!(scheduler::Scheduler)
	empty!(scheduler.forwarded)
	empty!(scheduler.results)
	scheduler
end

let scheduler_singleton = Scheduler()
	global default_scheduler() = scheduler_singleton
end




_arg_replacer(upstream) = Base.Fix2(_arg_replacer, upstream)
_arg_replacer(x, upstream) = get(upstream, x, x) # replaces (pre)fetched specs by the value, and leaves everything else in place

_unwrap_value(upstream) = Base.Fix2(_unwrap_value, upstream)
_unwrap_value() = _unwrap_value(IdDict{Spec,Any}())

function _unwrap_value(x, upstream)
	x isa Spec && return copy_nested(_unwrap_value(), upstream[x]) # Needed to handle e.g. a result which is a vector of `ReadOnly`s
	x isa ReadOnly && return x.value
	x
end


fetch_dependencies!(scheduler, deps) = IdDict{Spec,Any}(dep=>fetch!(scheduler, dep) for dep in deps)



function process_dependency!(f, scheduler, dep)
	dep = f(dep)
	dep.op === Call() && return dep # Already preprocessed as far as it gets
	process!(scheduler, dep)
end
process_dependencies!(f::F, scheduler, deps) where F =
	IdDict{Spec,Any}(dep=>process_dependency!(f, scheduler, dep) for dep in deps)
process_dependencies!(scheduler, deps) = process_dependencies!(identity, scheduler, deps)



function deduplicate_result(res)
	if res isa Spec
		res
	elseif res isa Managed
		# By returning a Managed result, the computing function takes responsibility of the contents, otherwise we need to standardize
		res = res.x
	else
		f = deduplicate_leaves(default_deduplicator()) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
		copy_nested(f, res)
	end
end


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
		res = deduplicate_result(res) # needed because forwarding can return a value
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

	replacer = _arg_replacer(upstream)

	args = Any[copy_nested(replacer, a) for a in sa.args]
	kwargs = Pair{Symbol,Any}[k=>copy_nested(replacer,v) for (k,v) in sa.kwargs]

	sa_forwarded = SpecArgs(sa.f, args, kwargs)
	return sa_forwarded
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

		unwrapper = _unwrap_value(upstream)
		args = (copy_nested(unwrapper, a) for a in sa.args)
		kwargs = (copy_nested(unwrapper, k)=>copy_nested(unwrapper,v) for (k,v) in sa.kwargs if !startswith(string(k),"__"))

		res = f(args...; kwargs...)
		@assert res !== nothing "Computation of $f returned nothing"
		res = deduplicate_result(res)
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


function _process_once!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, deps::Vector{Spec})
	sa = ro.value

	if is_preprocessing(sa)
		if !isempty(deps)
			forwarded_deps = process_dependencies!(scheduler, deps)
			sa = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
		end
		preprocessed = preprocess(sa)
		return preprocessed # Should we strip `op` for Specs here?
	end

	forwarded_deps = process_dependencies!(forwarded, scheduler, deps)
	sa_forwarded = replace_forwarded(sa, forwarded_deps)::Union{SpecArgs,ProcessingException}
	sa_forwarded isa ProcessingException && return sa_forwarded
	ro_forwarded = default_deduplicator()(sa_forwarded) # TODO: avoid using default_deduplicator() here - we need to get it from somewhere
	return Spec(ro_forwarded, Call())
end






# TODO: Move these somewhere else?
function get_cached end # `get_cached` is actually never called. We just use it as singleton value to show that something is using the on-disk cache.

# Use `sub` to retrieve parts of `CompoundResult`s
function cached(spec, sub::String...; return_keys=false)
	extra_kwargs = (return_keys ? (; return_keys) : (;)) # only pass kwarg if set to true
	create_spec(get_cached, spec, sub...; extra_kwargs..., __version=v"1.0.0")
end



# Helper function for recreating the Specs for retrieving individual parts of a CompoundResult
_cached_rewrap(ro, sub; kwargs...) = cached(Spec(ro, Call()), sub...; kwargs...).ro

function _insert_partial_results!(scheduler, ro, cr::CompoundResult, curr_sub=String[])
	# Insert keys as their own result
	scheduler.results[_cached_rewrap(ro,curr_sub; return_keys=true)] = first.(cr.children)
	for (k,v) in cr.children
		_insert_partial_results!(scheduler, ro, v, vcat(curr_sub, k))
	end
end
_insert_partial_results!(scheduler, ro, res, curr_sub) =
	scheduler.results[_cached_rewrap(ro,curr_sub)] = res





function cached_call!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, deps::Vector{Spec}; sub::Union{Nothing, Vector{String}}, return_keys::Bool)
	@assert all(x->x.op === Call(), deps) # Probably remove, it is already checked in process_once!
	sa = ro.value
	@assert sa.f !== get_cached # Probably remove, it is already checked in process_once!

	key = get_cache_key(ro)

	# Load from cache if it's already in there
	res = cache_load(key, sub; return_keys)
	res !== nothing && return res

	# Compute
	res = _fetch_and_compute!(scheduler, sa, deps)

	# Store in on-disk cache
	cache_save(key, res)

	if res isa CompoundResult
		# TODO: Figure out a better place to do this (we are currently inside a get!(scheduler.results, ro) call, so it works, but it is a bit awkward)
		# Insert all parts of the result into the in-RAM cache
		_insert_partial_results!(scheduler, ro, res)

		# sub === nothing && throw(ArgumentError("Cannot retrieve CompoundResult directly, sub-result must be specified."))

		# But only return the sub we asked for
		return get_subresult(res, sub; return_keys)
	else
		return_keys && throw(ArgumentError("return_keys can only be used on CompoundResults."))
		sub === nothing || throw(ArgumentError("Cannot retrieve sub-result unless the result is a CompoundResult (tried to retrieve: $sub)."))
		return res
	end
end

# Rename?
function standard_call!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, deps::Vector{Spec})
	sa = ro.value
	@assert all(x->x.op === Call(), deps) # Probably remove, it is already checked in process_once!

	@info "Bypassing cache"
	res = _fetch_and_compute!(scheduler, sa, deps)
	@assert !(res isa CompoundResult) # We only support CompoundResults when using the on-disk cache
	return res
end



# Return tuple with result and Bool telling if it's done (TODO: Make code more clear)
function process_once!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, op::T) where T
	sa = ro.value

	# Early out, we don't need to consider dependencies for this
	if T <: Forward && op.predicate(sa)
		return Spec(ro), true # should op ever be set to something here?
		# return Spec(ro, op), true # Maybe it makes more sense to keep the op in case it has some custom forwarding rule?
	end


	if is_preprocessing(sa)
		deps = get_dependencies(op->!(op isa Prefetch), sa) # No need to collect dependencies with op Prefetch, since they will not be changed.
	else
		deps = get_dependencies(sa)


		if all(s->s.op === Call(), deps)
			# ready to call

			# Stop if we are forwarding, nothing left to do
			T <: Forward && return (Spec(ro, Call()), true)

			if sa.f === get_cached
				inner_spec = sa.args[1]::Spec
				inner_ro = inner_spec.ro
				inner_sa = inner_ro.value
				@assert inner_sa.f !== get_cached # we cannot handle nested get_cached
				inner_deps = get_dependencies(inner_sa)
				@assert all(s->s.op === Call(), inner_deps) # The out Call has enforced all inner `op`s to be called has well.

				# The remaining args specify subresults of `CompoundResult`s
				sub = length(sa.args)==1 ? nothing : collect(String, @view(sa.args[2:end]))

				return_keys = _get_kwarg(sa.kwargs, :return_keys, false)

				res = get!(scheduler.results, ro) do # the key is the `get_cached` spec
					cached_call!(scheduler, inner_ro, inner_deps; sub, return_keys) # but we compute the inner spec
				end
			else
				res = get!(scheduler.results, ro) do
					standard_call!(scheduler, ro, deps)
				end
			end


			@assert !(res isa Spec)
			return res, true
		end
	end

	res = get!(scheduler.forwarded, ro) do
		_process_once!(scheduler, ro, deps) # Should we add op back in?
	end

	if res isa Spec
		return res, false
	else
		return res, true # forwarding returned a value, we are done
	end
end


function process!(scheduler::Scheduler, ro::ReadOnly{SpecArgs}, op::T) where T
	while true
		res, done = process_once!(scheduler, ro, op)
		done && return res
		res::Spec
		ro = res.ro
	end
end


fetch!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec.ro, Fetch())
forward!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec.ro, Forward())

function forward_once!(scheduler::Scheduler, spec::Spec)
	res, _ = process_once!(scheduler, spec.ro, Forward())
	res
end

process!(scheduler::Scheduler, spec::Spec) = process!(scheduler, spec.ro, spec.op)



# --- printing ---
function Base.show(io::IO, ::MIME"text/plain", scheduler::Scheduler)
	print(io, "Scheduler(")
	println("Results: ")
	compact_io = IOContext(io, :compact=>true)
	for (k,v) in scheduler.results
		show(compact_io, k)
		print(compact_io, " => ")
		show(compact_io, v)
		println(io)
	end
	print(io,')')
end
