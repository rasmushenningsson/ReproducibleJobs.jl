
struct SpecInitialized end

# TODO: This could be simplified a lot with mutually recursive type definitions. (We could store a SpecRef directly in that case, instead of sr and op.)
struct SpecWaiting{T} # Waiting for dependencies to finish
	downstream::Vector{Tuple{T,Tuple{T,Symbol}}} # Vector of sr=>(dep.sr,dep.op) pairs - so we know which dep to update in sr.state.upstream.
	upstream::IdDict{Tuple{T,Symbol},Any} # (sr,op)=>next/result
	n_upstream_left::Base.RefValue{Int}
	call::Bool # If set to true, all deps will be fetched!, and the owning spec will be computed after all deps are processed.
end
SpecWaiting(upstream::IdDict{Tuple{T,Symbol},Any}, n_upstream_left::Int, call::Bool) where T = SpecWaiting{T}([], upstream, Ref(n_upstream_left), call)
SpecWaiting() = SpecWaiting{SpecRun}([],IdDict{Tuple{SpecRun,Symbol},Any}(),Ref(0),false) # DUMMY USED DURING REFACTORING - TODO: Remove

struct SpecProcessing{T}
	downstream::Vector{Tuple{T,Tuple{T,Symbol}}} # Vector of sr=>(dep.sr,dep.op) pairs - so we know which dep to update in sr.state.upstream.
end # Running or Preprocessing
SpecProcessing() = SpecProcessing{SpecRun}([]) # DUMMY USED DURING REFACTORING - TODO: Remove

# TODO: This could be simplified a lot with mutually recursive type definitions. (We could store a SpecRef directly in that case, instead of sr and op.)
struct SpecNext{T}
	sr::T # This is always SpecRun, but we need a type parameter to handle the mutually recursive types.
	op::Symbol
end
# See below for constructor taking SpecRef


struct SpecResult
	result::Any
	weak_result::Any
end
SpecResult(result::Any) =
	SpecResult(result, deconstruct_weak_rec(result))

struct SpecErrored
	exception::Exception
end



struct Spec
	f::Any
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}

	function Spec(f, args, kwargs)
		@assert issorted(kwargs; by=first) # TODO: Also check that we don't have duplicate keys?
		new(f, args, kwargs)
	end
end

# Usually accessed through getproperty
get_function(spec::Spec) = spec.f
get_args(spec::Spec) = spec.args
get_kwargs(spec::Spec) = spec.kwargs



# const SpecStateUnion = Union{SpecInitialized, SpecWaiting{SpecRun}, SpecProcessing{SpecRun}, SpecNext{SpecRun}, SpecResult, SpecErrored}

mutable struct SpecRun
	const spec::Spec
	state::Union{SpecInitialized, SpecWaiting{SpecRun}, SpecProcessing{SpecRun}, SpecNext{SpecRun}, SpecResult, SpecErrored} # SpecStateUnion, but we cannot define it already because it uses SpecRun
end
SpecRun(spec::Spec) = SpecRun(spec, SpecInitialized())
SpecRun(sr::SpecRun) = sr


const SpecStateUnion = Union{SpecInitialized, SpecWaiting{SpecRun}, SpecProcessing{SpecRun}, SpecNext{SpecRun}, SpecResult, SpecErrored}


# Base.propertynames(::SpecRun, private::Bool=false) =
# 	private ? fieldnames(SpecRun) : (:f, :args, :kwargs)


# Usually accessed through getproperty
get_function(sr::SpecRun) = get_function(sr.spec)
get_args(sr::SpecRun) = get_args(sr.spec)
get_kwargs(sr::SpecRun) = get_kwargs(sr.spec)

function Base.getproperty(sr::SpecRun, s::Symbol)
	s === :f && return get_function(sr)
	s === :args && return get_args(sr)
	s === :kwargs && return get_kwargs(sr)
	getfield(sr, s)
end
Base.propertynames(::SpecRun, private::Bool=false) =
	private ? (:f, :args, :kwargs, :spec, :state) : (:f, :args, :kwargs)



# Doesn't create a new vector unless any child changed during deduplication
function _map_arg_vec(f, a::Vector{T}) where T
	out = a
	for (i,x) in enumerate(a)
		fx = f(x)
		if fx !== x
			if out === a
				out = copy(a)
			end
			out[i] = fx
		end
	end
	out
end




deduplicate_type(::Type{SpecRun}) = true
deduplication_pointer(sr::SpecRun) = pointer_from_objref(sr)
function deduplicate_children!(d, sr::SpecRun; kwargs...)
	f = sr.f # TODO: Should this be processed somehow? Probably not.

	a = _map_arg_vec(sr.args) do x
		deduplicate!(d, x; kwargs...)
	end
	kw = _map_arg_vec(sr.kwargs) do p
		p[1]=>deduplicate!(d, p[2]; kwargs...)
	end

	if f === sr.f && a === sr.args && kw === sr.kwargs
		sr # Not changed
	else
		SpecRun(Spec(f, a, kw))
	end
end
function deduplication_hash(d, sr::SpecRun)
	# TODO: Could we make this more efficient? (Is it a problem? Probably not.)

	# Tuple/NamedTuple version
	# f = sr.f
	# a = deduplication_hash(d, sr.args)
	# kw = deduplication_hash(d, sr.kwargs)
	# compute_hash(d, (TypeTag(:SpecRun), f, a, kw))

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = _map_arg_vec(sr.args) do x
		hash_or_value(d, x)
	end
	kw = _map_arg_vec(sr.kwargs) do p
		p[1]=>hash_or_value(d, p[2])
	end
	compute_hash(d, (TypeTag(:Spec), sr.f, a, kw))
end
deduplication_copy(sr::SpecRun) = sr


# TODO: THIS ISN'T GOOD ENOUGH! WE NEED TO ENSURE WE ONLY STORE EACH SPEC ONCE, EVEN IF IT'S REFERENCED MULTIPLE TIMES
function cache_save(io, name, sr::SpecRun)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "Spec"
	g["f"] = sr.f # Is this the best I can do?
	cache_save(g, "args", sr.args) # TODO: Must be fixed now that we use Vector{Any}
	cache_save(g, "kwargs", sr.kwargs) # TODO: Must be fixed now that we use Vector{Pair{Symbol,Any}}
	nothing
end
function cache_load(cache::Cache, ::Val{:Spec}, g)
	f = g["f"]
	args = cache_load(cache, g, "args") # TODO: Must be fixed now that we use Vector{Any}
	kwargs = cache_load(cache, g, "kwargs") # TODO: Must be fixed now that we use Vector{Pair{Symbol,Any}}
	sr = SpecRun(Spec(f, args, kwargs))
	deduplicate!(cache.deduplicator, sr; transfer_ownership=true)
end




function sa_isequal(a::SpecRun, b::SpecRun)
	a === b && return true # early out
	isequal(a.f, b.f) && sa_isequal(a.args, b.args) && sa_isequal(a.kwargs, b.kwargs)
end

function sa_isequal(a::AbstractVector{T1}, b::AbstractVector{T2}) where {T1,T2}
	isequal(length(a), length(b)) || return false
	all(t->sa_isequal(t[1], t[2]), zip(a,b))
end

function sa_isequal(a::Dict{K1,V1}, b::Dict{K2,V2}) where {K1,V1,K2,V2}
	isequal(length(a), length(b)) || return false
    for pair in a
        in(pair, b, sa_isequal) || return false
    end
    true
end

sa_isequal(a::NamedTuple{n}, b::NamedTuple{n}) where n = sa_isequal(Tuple(a), Tuple(b))
sa_isequal(a::NamedTuple, b::NamedTuple) = false # keys are different

function sa_isequal(a::DataFrame, b::DataFrame)
	isequal(ncol(a), ncol(b)) || return false
	isequal(names(a), names(b)) || return false
	all(t->sa_isequal(t[1], t[2]), zip(eachcol(a),eachcol(b)))
end

function sa_isequal(a::T1, b::T2) where {T1,T2}
	if deconstruct_type(T1) && deconstruct_type(T2)
		ad = deconstruct(a)::Tuple
		bd = deconstruct(b)::Tuple

		isequal(length(ad), length(bd)) || return false
		all(t->sa_isequal(t[1], t[2]), zip(ad,bd))
	else
		# TODO: Should we have this fallback?
		isequal(a,b)
	end
end

Base.isequal(a::SpecRun, b::SpecRun) = sa_isequal(a, b)




# Tuple/NamedTuple version
# _get_kwarg(sr::SpecRun, key::Symbol, default) = get(sr.kwargs, key, default)
# _get_kwarg(f, sr::SpecRun, key::Symbol) = get(f, sr.kwargs, key)
# _get_kwarg(sr::SpecRun, key::Symbol) = getindex(sr.kwargs, key)

# Vector{Any}/Vector{Pair{Symbol,Any}} version
function _find_kwarg(key::Symbol, kw::Vector{Pair{Symbol,Any}})
	for (i,(k,_)) in enumerate(kw)
		k == key && return i
	end
	return nothing
end
function _get_kwarg(f, sr::SpecRun, key::Symbol)
	i = _find_kwarg(key, sr.kwargs)
	i === nothing ? f() : sr.kwargs[i].second
end
_get_kwarg(sr::SpecRun, key::Symbol, default) = _get_kwarg(()->default, sr, key)
_get_kwarg(sr::SpecRun, key::Symbol) = _get_kwarg(()->throw(KeyError(key)), sr, key)



function set_result!(sr::SpecRun, res)
	if res isa Exception
		sr.state = SpecErrored(res)
	else
		sr.state = SpecResult(res)
	end
	sr
end


function get_result!(sr::SpecRun)
	if sr.state isa SpecResult
		sr = sr.state
		sr.result !== NotValid() && return sr.result
		if sr.weak_result !== NotValid()
			# Attempt to reconstruct from weakly stored reference
			result = reconstruct_weak_rec(sr.weak_result)
			if result !== NotValid()
				sr.state = SpecResult(result, sr.weak_result) # successful reconstruction
				return result
			end
			# sr.state = SpecResult(NotValid(), NotValid()) # failed to reconstruct, so the weak result is no longer relevant
			sr.state = SpecInitialized() # failed to reconstruct, so the weak result is no longer relevant
		end
		return NotValid()
	elseif sr.state isa SpecErrored
		return sr.state.exception
	end
	return NotValid()
end

function empty_result!(sr::SpecRun)
	if sr.state isa SpecResult
		# sr.state.result = NotValid()
		sr.state = SpecResult(NotValid(), sr.state.weak_result)
	elseif sr.state isa SpecErrored
		sr.state = SpecInitialized()
	end
	sr
end




Base.Broadcast.broadcastable(sr::SpecRun) = Ref(sr) # treat as scalar for broadcasting



struct SpecRef
	sr::SpecRun
	op::Symbol # :forward, :call, :fetch or :prefetch
	function SpecRef(sr::SpecRun, op::Symbol)
		@assert op in (:forward, :call, :fetch, :prefetch)
		new(sr, op)
	end
end
SpecRef(sr) = SpecRef(sr, :forward)


SpecNext(ref::SpecRef) = SpecNext{SpecRun}(ref.sr, ref.op) # workaround to handle mutually recursive types
SpecRef(next::SpecNext{SpecRun}) = SpecRef(next.sr, next.op)

Base.Broadcast.broadcastable(ref::SpecRef) = Ref(ref) # treat as scalar for broadcasting




# Usually accessed through getproperty
get_function(ref::SpecRef) = get_function(ref.sr)
get_args(ref::SpecRef) = get_args(ref.sr)
get_kwargs(ref::SpecRef) = get_kwargs(ref.sr)

function Base.getproperty(ref::SpecRef, s::Symbol)
	s === :f && return get_function(ref)
	s === :args && return get_args(ref)
	s === :kwargs && return get_kwargs(ref)
	getfield(ref, s)
end
Base.propertynames(::SpecRef, private::Bool=false) =
	private ? (:f, :args, :kwargs, :sr) : (:f, :args, :kwargs)

get_sr(ref::SpecRef) = ref.sr
SpecRun(ref::SpecRef) = get_sr(ref)


_get_kwarg(f, ref::SpecRef, key::Symbol) = _get_kwarg(f, get_sr(ref), key)
_get_kwarg(ref::SpecRef, key::Symbol, default) = _get_kwarg(get_sr(ref), key, default)
_get_kwarg(ref::SpecRef, key::Symbol) = _get_kwarg(get_sr(ref), key)



function transfer_op(src::SpecRef, dest::SpecRef)
	if src.op == :call
		dest.op === :call ? dest : SpecRef(get_sr(dest), :forward) # We can keep Call, but never transfer it (so fallback to standard forwarding)
	else
		SpecRef(get_sr(dest), src.op) # Transfer
	end
end



function try_get_result_rec(sr::SpecRun)
	if sr.state isa SpecResult
		sr.state.result, sr.state.weak_result
	elseif sr.state isa SpecNext{SpecRun}
		try_get_result_rec(sr.state.sr) # recurse
	else
		NotValid(), NotValid()
	end
end
try_get_result_rec(ref::SpecRef) = try_get_result_rec(get_sr(ref))




deduplicate_type(::Type{<:SpecRef}) = true
deconstruct_type(::Type{<:SpecRef}) = true
type_to_tag(::Type{SpecRef}) = TypeTag(:SpecRef)
tag_to_type(::Val{:SpecRef}) = SpecRef
deconstruct(ref::SpecRef) = (ref.sr, ref.op)
reconstruct(::Type{SpecRef}, (sr,op)::Tuple{SpecRun,Symbol}) = SpecRef(sr, op)




function create_spec(f, args...; scheduler=get_scheduler(), deduplicator=scheduler.deduplicator, kwargs...)
	# Tuple/NamedTuple version
	# kw = values(kwargs)
	# kw = sort_namedtuple_by_keys(kw)
	# sr = SpecRun(f, args, kw)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = collect(Any, args)
	kw = collect(Pair{Symbol,Any}, kwargs)
	sort!(kw; by=first)
	sr = SpecRun(Spec(f, a, kw))

	deduplicator !== nothing && (sr = deduplicate!(deduplicator, sr))
	SpecRef(sr)
end


Base.isequal(a::SpecRef, b::SpecRef) = isequal(a.op, b.op) && isequal(a.sr, b.sr)




function visit_dependencies(f, sr::SpecRun)
	# Tuple/NamedTuple version
	# visit_specs(f, sr.args)
	# visit_specs(f, sr.kwargs)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	# visit_specs.(Ref(f), sr.args)
	foreach(sr.args) do x
		visit_specs(f, x)
	end
	foreach(sr.kwargs) do p
		visit_specs(f, p[2])
	end
end
# visit_dependencies(f, ref::SpecRef) = visit_dependencies(f, ref.sr)


# NB: To visit all dependencies of a ref, call visit_dependencies on ref.
visit_specs(f, sr::SpecRun) = f(sr) # TODO: Get rid of this?
visit_specs(f, ref::SpecRef) = f(ref)

function visit_specs(f, v::AbstractVector{T}) where T
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	_deduplicate_eltype(T) && visit_specs.(Ref(f), v)
end
function visit_specs(f, d::Dict{K,V}) where {K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	_deduplicate_eltype(K) && visit_specs.(Ref(f), keys(d))
	_deduplicate_eltype(V) && visit_specs.(Ref(f), values(d))
end

function visit_specs(f, nt::T) where T<:NamedTuple
	foreach(x->visit_specs(f,x), nt)
end

function visit_specs(f, df::DataFrame)
	foreach(col->visit_specs(f,col), eachcol(df)) # This ensures we can put Specs as elements of DataFrame column vectors
end

function visit_specs(f, x::T) where T
	# @assert deconstruct_type(T) "visit_specs fallback only available for types that can be deconstructed, got $T."
	if deconstruct_type(T)
		xd = deconstruct(x)::Tuple
		visit_specs.(Ref(f), xd)
	else
		# TODO: Should we have this fallback? Or define visit_specs for everything including Int, String, etc.
		x
	end
end


# Find a better name?
function map_args(f::F, sr::SpecRun) where F
	# Tuple/NamedTuple version
	# a = map_specs(f, sr.args)
	# kw = map_specs(f, sr.kwargs)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = _map_arg_vec(sr.args) do x
		map_specs(f, x)
	end
	kw = _map_arg_vec(sr.kwargs) do p
		p[1]=>map_specs(f, p[2])
	end

	SpecRun(Spec(sr.f, a, kw))
end


# Find a better name?
# NB: To map all args/dependencies of a spec, call map_args on spec.
map_specs(f::F, sr::SpecRun) where F = @something f(sr) sr # TODO: Get rid of this?
map_specs(f::F, ref::SpecRef) where F = @something f(ref) ref

function _map_specs(f::F, v::AbstractVector{T}) where {F,T}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	if _deduplicate_eltype(T)
		ReadOnlyArray(map_specs.(Ref(f), v))
	else
		v # keep as is
	end
end
map_specs(f::F, v::AbstractVector{T}) where {F,T} = @something f(v) _map_specs(f, v)

function _map_specs(f::F, dict::Dict{K,V}) where {F,K,V}
	# The eltype check gives some false positives, but it prevents some unnecessary traversal and mostly gets the job done
	replace_keys = _deduplicate_eltype(K)
	replace_values = _deduplicate_eltype(V)

	if replace_keys && replace_values
		Dict(map_specs(f, k)=>map_specs(f, v) for (k,v) in dict)
	elseif replace_values
		Dict(k=>map_specs(f, v) for (k,v) in dict)
	elseif replace_keys
		Dict(map_specs(f, k)=>v for (k,v) in dict)
	else
		dict
	end
end
map_specs(f::F, dict::Dict{K,V}) where {F,K,V} = @something f(dict) _map_specs(f, dict)

map_specs(f::F, nt::T) where {F,T<:NamedTuple} =
	@something f(nt) map(x->map_specs(f,x), nt)

function map_specs(f::F, df::DataFrame) where F
	# This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
	@something f(df) DataFrame((name=>map_specs(f,col) for (name,col) in pairs(eachcol(df)))...; copycols=false)
end

function _map_specs(f::F, x::T) where {F,T}
	# @assert deconstruct_type(T) "map_specs fallback only available for types that can be deconstructed, got $T."
	if deconstruct_type(T)
		xd = deconstruct(x)::Tuple
		xd = map(x->map_specs(f,x), xd)
		reconstruct(T, xd)
	else
		# TODO: Should we have this fallback? Or define map_specs for everything including Int, String, etc.
		x
	end
end
map_specs(f::F, x::T) where {F,T} = @something f(x) _map_specs(f, x)



_fetched(::Any) = nothing
_fetched(ref::SpecRef) = SpecRef(ref.sr, :fetch)

_prefetched(::Any) = nothing
_prefetched(ref::SpecRef) = SpecRef(ref.sr, :prefetch)


fetched(x) = map_specs(_fetched, x)
prefetched(x) = map_specs(_prefetched, x)



# --- printing ---

_show_result(io::IO, x) = show(IOContext(io, :compact => true), x)
_show_result(io::IO, e::Exception) = show(io, typeof(e))
function _show_result(io::IO, df::DataFrame)
	print(io, summary(df))
	n = names(df)
	if !isempty(n)
		print(io, ": ")
		M = 10
		print(io, join(n[1:min(M,end)], ", "))
		length(n) > M && print(io, ", ...")
	end
end
function _show_result(io::IO, w::WeakRef)
	v = w.value
	if v !== nothing
		print(io, "WeakRef(")
		_show_result(io, v)
		print(io, ")")
	else
		print(io, styled"{red:Evicted}")
	end
end

function Base.show(io::IO, ref::SpecRef)
	if get(io,:compact,false)
		show(io, ref.f)
	else
		print_spec(io, ref; maxdepth=5)
		result, weak_result = try_get_result_rec(ref)

		if result !== NotValid()
			print(io, "Result: ")
			_show_result(io, result)
		elseif weak_result !== NotValid()
			print(io, "Result: ")
			_show_result(io, weak_result)
		end
	end
end
