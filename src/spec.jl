mutable struct Spec # TODO: Add template parameters for args/kwargs? Or find a another way to handle types better?
	f::Any
	# args::Tuple
	# kwargs::NamedTuple
	args::Vector{Any}
	kwargs::Vector{Pair{Symbol,Any}}

	# Cache (forwarding)
	# This is the result of `process_once`, when preprocessing.
	# Later, we might want to make this a sumtype. (But then we need mutually recursive types, which is not yet supported by Julia.)
	next::Any # NotValid means it is not computed. Most often a WrappedSpec. Can also be a value (in rare cases specs forwards to values).

	# Cache (result)
	result::Any
	weak_result::Any

	function Spec(f, args, kwargs)
		# @assert issorted(keys(kwargs))
		@assert issorted(kwargs; by=first) # TODO: Also check that we don't have duplicate keys?
		new(f, args, kwargs, NotValid(), NotValid(), NotValid())
	end
end
Spec(spec::Spec) = spec

Base.propertynames(::Spec, private::Bool=false) =
	private ? fieldnames(Spec) : (:f, :args, :kwargs)


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




deduplicate_type(::Type{Spec}) = true
deduplication_pointer(spec::Spec) = pointer_from_objref(spec)
function deduplicate_children!(d, spec::Spec; kwargs...)
	f = spec.f # TODO: Should this be processed somehow? Probably not.

	# Tuple/NamedTuple version
	# a = deduplicate!(d, spec.args; kwargs...)
	# kw = deduplicate!(d, spec.kwargs; kwargs...)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	# a = _deduplicate_args(d, spec.args; kwargs...)
	# kw = _deduplicate_args(d, spec.kwargs; kwargs...)
	a = _map_arg_vec(spec.args) do x
		deduplicate!(d, x; kwargs...)
	end
	kw = _map_arg_vec(spec.kwargs) do p
		p[1]=>deduplicate!(d, p[2]; kwargs...)
	end

	if f === spec.f && a === spec.args && kw === spec.kwargs
		spec # Not changed
	else
		Spec(f, a, kw)
	end
end
function deduplication_hash(d, spec::Spec)
	# TODO: Could we make this more efficient? (Is it a problem? Probably not.)

	# Tuple/NamedTuple version
	# f = spec.f
	# a = deduplication_hash(d, spec.args)
	# kw = deduplication_hash(d, spec.kwargs)
	# compute_hash(d, (TypeTag(:Spec), f, a, kw))

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = _map_arg_vec(spec.args) do x
		hash_or_value(d, x)
	end
	kw = _map_arg_vec(spec.kwargs) do p
		p[1]=>hash_or_value(d, p[2])
	end
	compute_hash(d, (TypeTag(:Spec), spec.f, a, kw))
end
deduplication_copy(spec::Spec) = spec


# TODO: THIS ISN'T GOOD ENOUGH! WE NEED TO ENSURE WE ONLY STORE EACH SPEC ONCE, EVEN IF IT'S REFERENCED MULTIPLE TIMES
function cache_save(io, name, spec::Spec)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "Spec"
	g["f"] = spec.f # Is this the best I can do?
	cache_save(g, "args", spec.args) # TODO: Must be fixed now that we use Vector{Any}
	cache_save(g, "kwargs", spec.kwargs) # TODO: Must be fixed now that we use Vector{Pair{Symbol,Any}}
	nothing
end
function cache_load(cache::Cache, ::Val{:Spec}, g)
	f = g["f"]
	args = cache_load(cache, g, "args") # TODO: Must be fixed now that we use Vector{Any}
	kwargs = cache_load(cache, g, "kwargs") # TODO: Must be fixed now that we use Vector{Pair{Symbol,Any}}
	spec = Spec(f, args, kwargs)
	deduplicate!(cache.deduplicator, spec; transfer_ownership=true)
end




function sa_isequal(a::Spec, b::Spec)
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

Base.isequal(a::Spec, b::Spec) = sa_isequal(a, b)




# Tuple/NamedTuple version
# _get_kwarg(spec::Spec, key::Symbol, default) = get(spec.kwargs, key, default)
# _get_kwarg(f, spec::Spec, key::Symbol) = get(f, spec.kwargs, key)
# _get_kwarg(spec::Spec, key::Symbol) = getindex(spec.kwargs, key)

# Vector{Any}/Vector{Pair{Symbol,Any}} version
function _find_kwarg(key::Symbol, kw::Vector{Pair{Symbol,Any}})
	for (i,(k,_)) in enumerate(kw)
		k == key && return i
	end
	return nothing
end
function _get_kwarg(f, spec::Spec, key::Symbol)
	i = _find_kwarg(key, spec.kwargs)
	i === nothing ? f() : spec.kwargs[i].second
end
_get_kwarg(spec::Spec, key::Symbol, default) = _get_kwarg(()->default, spec, key)
_get_kwarg(spec::Spec, key::Symbol) = _get_kwarg(()->throw(KeyError(key)), spec, key)


# TODO: Make this code easier to read
function get_next!(f, spec::Spec)
	if spec.next === NotValid()
		spec.next = f()
	end
	spec.next
end

# TODO: Make this code easier to read
function get_result!(f, spec::Spec)
	spec.result !== NotValid() && return spec.result

	if spec.weak_result !== NotValid()
		# Attempt to reconstruct from weakly stored reference
		spec.result = reconstruct_weak_rec(spec.weak_result)
		spec.result !== NotValid() && return spec.result
		spec.weak_result = NotValid()
	end

	# Compute result
	result = f()
	if !(result isa InterruptException)
		spec.result = result
		spec.weak_result = deconstruct_weak_rec(spec.result)
	end
	return result
end

# NB: Any weak result will still be present and the result can thus still be reconstructed if it has not yet been GCed.
empty_result!(spec::Spec) = (spec.result = NotValid(); spec)




Base.Broadcast.broadcastable(spec::Spec) = Ref(spec) # treat as scalar for broadcasting



struct WrappedSpec
	spec::Spec
	op::Symbol # :forward, :call, :fetch or :prefetch
end
WrappedSpec(spec) = WrappedSpec(spec, :forward)

Base.Broadcast.broadcastable(ws::WrappedSpec) = Ref(ws) # treat as scalar for broadcasting




# Usually accessed through getproperty
get_function(ws::WrappedSpec) = ws.spec.f
get_args(ws::WrappedSpec) = ws.spec.args
get_kwargs(ws::WrappedSpec) = ws.spec.kwargs

function Base.getproperty(ws::WrappedSpec, s::Symbol)
	s === :f && return get_function(ws)
	s === :args && return get_args(ws)
	s === :kwargs && return get_kwargs(ws)
	getfield(ws, s)
end
Base.propertynames(::WrappedSpec, private::Bool=false) =
	private ? (:f, :args, :kwargs, :spec) : (:f, :args, :kwargs)


# TODO: Rename to get_spec?
get_sa(spec::Spec) = spec
get_sa(ws::WrappedSpec) = ws.spec

Spec(ws::WrappedSpec) = get_sa(ws)


function transfer_op(src::WrappedSpec, dest::Union{Spec,WrappedSpec})
	if src.op == :call
		dest.op === :call ? dest : WrappedSpec(get_sa(dest), :forward) # We can keep Call, but never transfer it (so fallback to standard forwarding)
	else
		WrappedSpec(get_sa(dest), src.op) # Transfer
	end
end



function try_get_result_rec(spec::Spec)
	if spec.result !== NotValid() || spec.weak_result !== NotValid()
		spec.result, spec.weak_result
	elseif spec.next !== NotValid()
		if spec.next isa WrappedSpec
			try_get_result_rec(spec.next) # recurse
		else
			spec.next, NotValid() # it forwarded to a value
		end
	else
		NotValid(), NotValid()
	end
end
try_get_result_rec(ws::WrappedSpec) = try_get_result_rec(get_sa(ws))




deduplicate_type(::Type{<:WrappedSpec}) = true
deconstruct_type(::Type{<:WrappedSpec}) = true
type_to_tag(::Type{WrappedSpec}) = TypeTag(:WrappedSpec)
tag_to_type(::Val{:WrappedSpec}) = WrappedSpec
deconstruct(ws::WrappedSpec) = (ws.spec,ws.op)
reconstruct(::Type{WrappedSpec}, (spec,op)::Tuple{Spec,Symbol}) = WrappedSpec(spec, op)




function create_spec(f, args...; scheduler=get_scheduler(), deduplicator=scheduler.deduplicator, kwargs...)
	# Tuple/NamedTuple version
	# kw = values(kwargs)
	# kw = sort_namedtuple_by_keys(kw)
	# spec = Spec(f, args, kw)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = collect(Any, args)
	kw = collect(Pair{Symbol,Any}, kwargs)
	sort!(kw; by=first)
	spec = Spec(f, a, kw)

	deduplicator !== nothing && (spec = deduplicate!(deduplicator, spec))
	WrappedSpec(spec)
end


Base.isequal(a::WrappedSpec, b::WrappedSpec) = isequal(a.op, b.op) && isequal(a.spec, b.spec)




function visit_dependencies(f, spec::Spec)
	# Tuple/NamedTuple version
	# visit_specs(f, spec.args)
	# visit_specs(f, spec.kwargs)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	# visit_specs.(Ref(f), spec.args)
	foreach(spec.args) do x
		visit_specs(f, x)
	end
	foreach(spec.kwargs) do p
		visit_specs(f, p[2])
	end
end
# visit_dependencies(f, ws::WrappedSpec) = visit_dependencies(f, ws.spec)


# NB: To visit all dependencies of a spec, call visit_dependencies on spec.
visit_specs(f, spec::Spec) = f(spec)
visit_specs(f, ws::WrappedSpec) = f(ws)

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
	foreach(col->visit_specs(f,col), eachcol(df)) # This handles the somewhat strange case of putting Specs as elements of DataFrame column vectors
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
function map_args(f::F, spec::Spec) where F
	# Tuple/NamedTuple version
	# a = map_specs(f, spec.args)
	# kw = map_specs(f, spec.kwargs)

	# Vector{Any}/Vector{Pair{Symbol,Any}} version
	a = _map_arg_vec(spec.args) do x
		map_specs(f, x)
	end
	kw = _map_arg_vec(spec.kwargs) do p
		p[1]=>map_specs(f, p[2])
	end

	Spec(spec.f, a, kw)
end


# Find a better name?
# NB: To map all args/dependencies of a spec, call map_args on spec.
map_specs(f::F, spec::Spec) where F = @something f(spec) spec
map_specs(f::F, ws::WrappedSpec) where F = @something f(ws) ws

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
_fetched(ws::WrappedSpec) = WrappedSpec(ws.spec, :fetch)

_prefetched(::Any) = nothing
_prefetched(ws::WrappedSpec) = WrappedSpec(ws.spec, :prefetch)


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

function Base.show(io::IO, spec::WrappedSpec)
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
