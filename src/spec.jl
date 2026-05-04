
struct SpecInitialized end
# struct SpecWaiting end # TODO: Add
# struct SpecProcessing end # TODO: Add

# struct SpecNext
# 	# Ideally, this should store a Spec, but that's not possible without mutually recursive type definitions.
# 	sa::SpecArgs
# 	op::Symbol
# end

# TODO: This could be simplified a lot with mutually recursive type definitions. (We could store a Spec directly in that case.)
struct SpecNext{T}
	# Ideally, this should store a Spec, but that's not possible without mutually recursive type definitions.
	sa::T
	op::Symbol
end
# See below for constructor taking Spec


struct SpecResult
	result::Any
	weak_result::Any
end
SpecResult(result::Any) =
	SpecResult(result, deconstruct_weak_rec(result))

struct SpecErrored
	exception::Exception
end




# const SpecStateUnion = Union{SpecInitialized, SpecNext, SpecResult, SpecErrored}

# TODO: Can we find a better name for this struct?
mutable struct SpecArgs # TODO: Add template parameters for args/kwargs? Or find a another way to handle types better?
	const f::Any
	# args::Tuple
	# kwargs::NamedTuple
	const args::Vector{Any}
	const kwargs::Vector{Pair{Symbol,Any}}

	state::Union{SpecInitialized, SpecNext{SpecArgs}, SpecResult, SpecErrored} # SpecStateUnion, but we cannot define it already because it uses SpecArgs

	function SpecArgs(f, args, kwargs)
		# @assert issorted(keys(kwargs))
		@assert issorted(kwargs; by=first) # TODO: Also check that we don't have duplicate keys?
		new(f, args, kwargs, SpecInitialized())
	end
end
SpecArgs(sa::SpecArgs) = sa


const SpecStateUnion = Union{SpecInitialized, SpecNext{SpecArgs}, SpecResult, SpecErrored}


Base.propertynames(::SpecArgs, private::Bool=false) =
	private ? fieldnames(SpecArgs) : (:f, :args, :kwargs)


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




deduplicate_type(::Type{SpecArgs}) = true
deduplication_pointer(sa::SpecArgs) = pointer_from_objref(sa)
function deduplicate_children!(d, sa::SpecArgs; kwargs...)
	f = sa.f # TODO: Should this be processed somehow? Probably not.

	# Tuple/NamedTuple version
	# a = deduplicate!(d, sa.args; kwargs...)
	# kw = deduplicate!(d, sa.kwargs; kwargs...)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	# a = _deduplicate_args(d, sa.args; kwargs...)
	# kw = _deduplicate_args(d, sa.kwargs; kwargs...)
	a = _map_arg_vec(sa.args) do x
		deduplicate!(d, x; kwargs...)
	end
	kw = _map_arg_vec(sa.kwargs) do p
		p[1]=>deduplicate!(d, p[2]; kwargs...)
	end

	if f === sa.f && a === sa.args && kw === sa.kwargs
		sa # Not changed
	else
		SpecArgs(f, a, kw)
	end
end
function deduplication_hash(d, sa::SpecArgs)
	# TODO: Could we make this more efficient? (Is it a problem? Probably not.)

	# Tuple/NamedTuple version
	# f = sa.f
	# a = deduplication_hash(d, sa.args)
	# kw = deduplication_hash(d, sa.kwargs)
	# compute_hash(d, (TypeTag(:SpecArgs), f, a, kw))

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = _map_arg_vec(sa.args) do x
		hash_or_value(d, x)
	end
	kw = _map_arg_vec(sa.kwargs) do p
		p[1]=>hash_or_value(d, p[2])
	end
	compute_hash(d, (TypeTag(:SpecArgs), sa.f, a, kw))
end
deduplication_copy(sa::SpecArgs) = sa


# TODO: THIS ISN'T GOOD ENOUGH! WE NEED TO ENSURE WE ONLY STORE EACH SPEC ONCE, EVEN IF IT'S REFERENCED MULTIPLE TIMES
function cache_save(io, name, sa::SpecArgs)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "SpecArgs"
	g["f"] = sa.f # Is this the best I can do?
	cache_save(g, "args", sa.args) # TODO: Must be fixed now that we use Vector{Any}
	cache_save(g, "kwargs", sa.kwargs) # TODO: Must be fixed now that we use Vector{Pair{Symbol,Any}}
	nothing
end
function cache_load(cache::Cache, ::Val{:SpecArgs}, g)
	f = g["f"]
	args = cache_load(cache, g, "args") # TODO: Must be fixed now that we use Vector{Any}
	kwargs = cache_load(cache, g, "kwargs") # TODO: Must be fixed now that we use Vector{Pair{Symbol,Any}}
	sa = SpecArgs(f, args, kwargs)
	deduplicate!(cache.deduplicator, sa; transfer_ownership=true)
end




function sa_isequal(a::SpecArgs, b::SpecArgs)
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

Base.isequal(a::SpecArgs, b::SpecArgs) = sa_isequal(a, b)




# Tuple/NamedTuple version
# _get_kwarg(sa::SpecArgs, key::Symbol, default) = get(sa.kwargs, key, default)
# _get_kwarg(f, sa::SpecArgs, key::Symbol) = get(f, sa.kwargs, key)
# _get_kwarg(sa::SpecArgs, key::Symbol) = getindex(sa.kwargs, key)

# Vector{Any}/Vector{Pair{Symbol,Any}} version
function _find_kwarg(key::Symbol, kw::Vector{Pair{Symbol,Any}})
	for (i,(k,_)) in enumerate(kw)
		k == key && return i
	end
	return nothing
end
function _get_kwarg(f, sa::SpecArgs, key::Symbol)
	i = _find_kwarg(key, sa.kwargs)
	i === nothing ? f() : sa.kwargs[i].second
end
_get_kwarg(sa::SpecArgs, key::Symbol, default) = _get_kwarg(()->default, sa, key)
_get_kwarg(sa::SpecArgs, key::Symbol) = _get_kwarg(()->throw(KeyError(key)), sa, key)



function set_result!(sa::SpecArgs, res)
	if res isa Exception
		sa.state = SpecErrored(res)
	else
		sa.state = SpecResult(res)
	end
	sa
end


function get_result!(sa::SpecArgs)
	if sa.state isa SpecResult
		sr = sa.state
		sr.result !== NotValid() && return sr.result
		if sr.weak_result !== NotValid()
			# Attempt to reconstruct from weakly stored reference
			result = reconstruct_weak_rec(sr.weak_result)
			if result !== NotValid()
				sa.state = SpecResult(result, sr.weak_result) # successful reconstruction
				return result
			end
			# sa.state = SpecResult(NotValid(), NotValid()) # failed to reconstruct, so the weak result is no longer relevant
			sa.state = SpecInitialized() # failed to reconstruct, so the weak result is no longer relevant
		end
		return NotValid()
	elseif sa.state isa SpecErrored
		return sa.state.exception
	end
	return NotValid()
end

function empty_result!(sa::SpecArgs)
	if sa.state isa SpecResult
		# sa.state.result = NotValid()
		sa.state = SpecResult(NotValid(), sa.state.weak_result)
	elseif sa.state isa SpecErrored
		sa.state = SpecInitialized()
	end
	sa
end




Base.Broadcast.broadcastable(sa::SpecArgs) = Ref(sa) # treat as scalar for broadcasting



struct Spec
	sa::SpecArgs
	op::Symbol # :forward, :call, :fetch or :prefetch
	function Spec(sa::SpecArgs, op::Symbol)
		@assert op in (:forward, :call, :fetch, :prefetch)
		new(sa, op)
	end
end
Spec(sa) = Spec(sa, :forward)


SpecNext(spec::Spec) = SpecNext{SpecArgs}(spec.sa, spec.op) # workaround to handle mutually recursive types
Spec(next::SpecNext{SpecArgs}) = Spec(next.sa, next.op)

Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting




# Usually accessed through getproperty
get_function(spec::Spec) = spec.sa.f
get_args(spec::Spec) = spec.sa.args
get_kwargs(spec::Spec) = spec.sa.kwargs

function Base.getproperty(spec::Spec, s::Symbol)
	s === :f && return get_function(spec)
	s === :args && return get_args(spec)
	s === :kwargs && return get_kwargs(spec)
	getfield(spec, s)
end
Base.propertynames(::Spec, private::Bool=false) =
	private ? (:f, :args, :kwargs, :spec) : (:f, :args, :kwargs)

get_sa(spec::Spec) = spec.sa
SpecArgs(spec::Spec) = get_sa(spec)


_get_kwarg(f, spec::Spec, key::Symbol) = _get_kwarg(f, get_sa(spec), key)
_get_kwarg(spec::Spec, key::Symbol, default) = _get_kwarg(get_sa(spec), key, default)
_get_kwarg(spec::Spec, key::Symbol) = _get_kwarg(get_sa(spec), key)



function transfer_op(src::Spec, dest::Spec)
	if src.op == :call
		dest.op === :call ? dest : Spec(get_sa(dest), :forward) # We can keep Call, but never transfer it (so fallback to standard forwarding)
	else
		Spec(get_sa(dest), src.op) # Transfer
	end
end



function try_get_result_rec(sa::SpecArgs)
	if sa.state isa SpecResult
		sa.state.result, sa.state.weak_result
	elseif sa.state isa SpecNext{SpecArgs}
		try_get_result_rec(sa.state.sa) # recurse
	else
		NotValid(), NotValid()
	end
end
try_get_result_rec(spec::Spec) = try_get_result_rec(get_sa(spec))




deduplicate_type(::Type{<:Spec}) = true
deconstruct_type(::Type{<:Spec}) = true
type_to_tag(::Type{Spec}) = TypeTag(:Spec)
tag_to_type(::Val{:Spec}) = Spec
deconstruct(spec::Spec) = (spec.sa, spec.op)
reconstruct(::Type{Spec}, (sa,op)::Tuple{SpecArgs,Symbol}) = Spec(sa, op)




function create_spec(f, args...; scheduler=get_scheduler(), deduplicator=scheduler.deduplicator, kwargs...)
	# Tuple/NamedTuple version
	# kw = values(kwargs)
	# kw = sort_namedtuple_by_keys(kw)
	# sa = SpecArgs(f, args, kw)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = collect(Any, args)
	kw = collect(Pair{Symbol,Any}, kwargs)
	sort!(kw; by=first)
	sa = SpecArgs(f, a, kw)

	deduplicator !== nothing && (sa = deduplicate!(deduplicator, sa))
	Spec(sa)
end


Base.isequal(a::Spec, b::Spec) = isequal(a.op, b.op) && isequal(a.sa, b.sa)




function visit_dependencies(f, sa::SpecArgs)
	# Tuple/NamedTuple version
	# visit_specs(f, sa.args)
	# visit_specs(f, sa.kwargs)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	# visit_specs.(Ref(f), sa.args)
	foreach(sa.args) do x
		visit_specs(f, x)
	end
	foreach(sa.kwargs) do p
		visit_specs(f, p[2])
	end
end
# visit_dependencies(f, spec::Spec) = visit_dependencies(f, spec.sa)


# NB: To visit all dependencies of a spec, call visit_dependencies on spec.
visit_specs(f, sa::SpecArgs) = f(sa) # TODO: Get rid of this?
visit_specs(f, spec::Spec) = f(spec)

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
function map_args(f::F, sa::SpecArgs) where F
	# Tuple/NamedTuple version
	# a = map_specs(f, sa.args)
	# kw = map_specs(f, sa.kwargs)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = _map_arg_vec(sa.args) do x
		map_specs(f, x)
	end
	kw = _map_arg_vec(sa.kwargs) do p
		p[1]=>map_specs(f, p[2])
	end

	SpecArgs(sa.f, a, kw)
end


# Find a better name?
# NB: To map all args/dependencies of a spec, call map_args on spec.
map_specs(f::F, sa::SpecArgs) where F = @something f(sa) sa # TODO: Get rid of this?
map_specs(f::F, spec::Spec) where F = @something f(spec) spec

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
_fetched(spec::Spec) = Spec(spec.sa, :fetch)

_prefetched(::Any) = nothing
_prefetched(spec::Spec) = Spec(spec.sa, :prefetch)


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

function Base.show(io::IO, spec::Spec)
	if get(io,:compact,false)
		show(io, spec.f)
	else
		print_spec(io, spec; maxdepth=5)
		result, weak_result = try_get_result_rec(spec)

		if result !== NotValid()
			print(io, "Result: ")
			_show_result(io, result)
		elseif weak_result !== NotValid()
			print(io, "Result: ")
			_show_result(io, weak_result)
		end
	end
end
