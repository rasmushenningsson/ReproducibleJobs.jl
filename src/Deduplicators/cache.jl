struct Cache{K,H}
	deduplicator::Deduplicator{H}

	# In-memory cache
	# mem::Dict{Hash,WeakRef} # Value is a WeakRef to the result
	mem::WeakKeyDict{K, Any} # Value contains the output of deconstruct_weak_rec, i.e. mutable objects such as Vectors are stored using WeakRefs

	# On-disk cache
	dir::Union{String, Nothing}
end
function Cache(::Type{K}, deduplicator::Deduplicator{H}; dir=get_cache_path()) where {K,H}
	if dir !== nothing
		dir = abspath(dir) # In case the user changes working directory afterwards
	end
	Cache{K,H}(deduplicator, Dict(), dir)
end

function Base.empty!(cache::Cache)
	empty!(cache.mem)
	cache
end



struct NotValid end # we cannot use Nothing below, because that could be a real value

struct DeconstructedWeak{R,T<:Union{<:Tuple,<:NamedTuple}} # TODO: Decide how to handle NamedTuple
	value::T
end
DeconstructedWeak(::Type{R}, value::T) where {R,T} = DeconstructedWeak{R,T}(value)

function deconstruct_weak_rec(x::T) where T
	if deconstruct_type(T)
		xd = map(deconstruct_weak_rec, deconstruct(x))
		return DeconstructedWeak(T, xd)
	else
		@assert ismutabletype(T) "Unexpected type: $T"
		return WeakRef(x) # Use TypedWeakRef instead?
	end
end
function deconstruct_weak_rec(nt::T) where T<:NamedTuple # TODO: Decide how to handle NamedTuple
	ntd = map(deconstruct_weak_rec, nt)
	return DeconstructedWeak(T, ntd)
end

# Experimental
function deconstruct_weak_rec(cr::CompoundResult)
	WeakCompoundResult(cr.keys, Any[deconstruct_weak_rec(v) for v in cr.values])
end

deconstruct_weak_rec(x::Union{<:Number,String,Symbol,Char,DataType,Colon,Nothing,Missing,VersionNumber,Regex}) = x
deconstruct_weak_rec(x::AbstractUnitRange{T}) where T<:Union{Number,Char} = x
deconstruct_weak_rec(x::AbstractRange{T}) where T<:Union{Number,Char} = x
deconstruct_weak_rec(x::SupportedFunctions) = x
deconstruct_weak_rec(x::ROArray{T,N}) where {T,N} = deconstruct_weak_rec(parent(x))
deconstruct_weak_rec(x::ROBitArray{N}) where N = deconstruct_weak_rec(parent(x))

deconstruct_weak_rec(x::T) where T<:Exception = x


function reconstruct_weak_rec(dw::DeconstructedWeak{R,T}) where {R,T<:Tuple}
	xd = map(reconstruct_weak_rec, dw.value)
	any(==(NotValid()), xd) && return NotValid()
	reconstruct(R,xd)::R
end
function reconstruct_weak_rec(dw::DeconstructedWeak{R,T}) where {R,T<:NamedTuple} # TODO: Decide how to handle NamedTuple
	ntd = map(reconstruct_weak_rec, dw.value)
	any(==(NotValid()), ntd) && return NotValid()
	ntd::R
end
function reconstruct_weak_rec(w::WeakRef)
	value = w.value
	value !== nothing ? deduplication_postprocess(value) : NotValid() # deduplication_postprocess is used to wrap in ReadOnlyArray
end
reconstruct_weak_rec(x::Union{<:Number,String,Symbol,Char,DataType,Colon,Nothing,Missing,VersionNumber,Regex}) = x
reconstruct_weak_rec(x::AbstractUnitRange{T}) where T<:Union{Number,Char} = x
reconstruct_weak_rec(x::AbstractRange{T}) where T<:Union{Number,Char} = x
reconstruct_weak_rec(x::SupportedFunctions) = x

reconstruct_weak_rec(x::T) where T<:Exception = x


function cache_mem_get(cache::Cache{K}, key::K) where K
	w = get(cache.mem, key, NotValid())
	w === NotValid() && return NotValid()
	reconstruct_weak_rec(w)
end
function cache_mem_set!(cache::Cache{K}, key::K, value) where K
	cache.mem[key] = deconstruct_weak_rec(value)
	# cache.mem[key] = WeakRef(value)
	cache
end




function key2path(cache::Cache{K}, key::K) where K
	h = lookup_hash(cache.deduplicator, key)
	@assert h !== nothing "Only deduplicated keys are allowed."
	joinpath(cache.dir, string(hash_string(h),".jld2"))
end






struct CustomStorage{T}
	value::T
end

function JLD2.writeas(::Type{CustomStorage{T}}) where T
	error("Custom storage conversion not handled for type $T.")
end


# function custom_wrap(x::T) where T<:Union{<:Number,String,Symbol,Char,DataType,Colon,Nothing,Missing}
# 	x
# end

custom_unwrap(x::Any) = x
custom_unwrap(x::CustomStorage{T}) where T = x.value


custom_wrap(x::Regex) = CustomStorage(x)
JLD2.writeas(::Type{CustomStorage{Regex}}) = String
JLD2.wconvert(::Type{String}, cs::CustomStorage{Regex}) = repr(cs.value)
function JLD2.rconvert(::Type{CustomStorage{Regex}}, value::String)
	@assert startswith(value, "r\"")
	i = findlast('\"', value)::Int
	pattern = @views value[3:i-1]
	flags = @views value[i+1:end]
	CustomStorage(Regex(pattern, flags))
end

custom_wrap(x::VersionNumber) = CustomStorage(x)
JLD2.writeas(::Type{CustomStorage{VersionNumber}}) = String
JLD2.wconvert(::Type{String}, cs::CustomStorage{VersionNumber}) = string(cs.value)
JLD2.rconvert(::Type{CustomStorage{VersionNumber}}, value::String) = CustomStorage(VersionNumber(value))


custom_wrap(x::SupportedFunctions) = CustomStorage(x)
JLD2.writeas(::Type{CustomStorage{T}}) where T<:SupportedFunctions = String
JLD2.wconvert(::Type{String}, cs::CustomStorage{T}) where T<:SupportedFunctions = string(cs.value)
JLD2.rconvert(::Type{CustomStorage{T}}, value::String) where T<:SupportedFunctions = CustomStorage(getproperty(Base,Symbol(value)))



function _store_eltype_union_rec(::Type{T}) where T
	if T isa Union
		_store_eltype_union_rec(T.a) && _store_eltype_union_rec(T.b) # recursion handles Unions of more than two types
	else
		isbitstype(T) || T == String || T == Symbol
	end
end
function store_eltype_union(::Type{T}) where T
	T isa Union ? _store_eltype_union_rec(T) : false
end

function split_union_type(::Type{T}) where T
	if T isa Union
		(split_union_type(T.a)..., split_union_type(T.b)...)
	else
		(T,)
	end
end




function cache_load(cache::Cache, io, name)
	x = io[name]
	if x isa JLD2.Group
		type = Symbol(x["type"]::String)
		cache_load(cache, Val(type), x)
	else
		# custom_unwrap(x)

		x = custom_unwrap(x)

		# Find a nice way to do this?
		if x isa Union{<:Array, <:BitArray}
			x = ReadOnlyArray(x)
		end
		x

		# # Deduplicate pointer-backed objects as soon as they are loaded
		# x = custom_unwrap(x)
		# if deduplication_pointer(x) !== nothing # Can we express this in a nicer way?
		# 	x = deduplicate!(cache.deduplicator, x; transfer_ownership=true)
		# end
		# x
	end
end

function cache_save(io, name, x::T) where T<:Union{<:Number,String,Symbol,Char,DataType,Colon,Nothing,Missing}
	io[name] = x
	nothing
end
function cache_save(io, name, x::T) where T<:Union{VersionNumber,Regex}
	io[name] = custom_wrap(x)
	nothing
end

function cache_save(io, name, x::AbstractRange{T}) where T<:Union{Number,Char}
	io[name] = x
	nothing
end
function cache_save(io, name, x::AbstractUnitRange{T}) where T<:Union{Number,Char}
	io[name] = x
	nothing
end


function cache_save(io, name, x::T) where T<:SupportedFunctions
	io[name] = custom_wrap(x)
	nothing
end


# Default implementation (only possible for deconstructed types)
function cache_save(io, name, x::T) where T
	@assert deconstruct_type(T) "cache_save fallback only available for types that can be deconstructed, got $T."
	xd = deconstruct(x)::Tuple
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = String(type_to_tag(T).name)
	g["length"] = length(xd)
	for (i,xi) in enumerate(xd)
		cache_save(g, string(i), xi)
	end
end
# Default implementation (only possible for deconstructed types)
function cache_load(cache::Cache, val::Val{S}, g) where S
	T = tag_to_type(val)
	@assert deconstruct_type(T) "cache_load fallback only available for types that can be deconstructed, got $T."
	len = g["length"]
	t = cache_load.(Ref(cache), Ref(g), ntuple(string, len))
	reconstruct(T, t)
end



_index_to_string(i::Int) = string(i)
_index_to_string(I::CartesianIndex) = join(Tuple(I), '_')


function _cache_save_string_array(io, name, type_str, result::Array{T,N}) where {T,N}
	g = JLD2.Group(io, name)
	g["type"] = type_str
	g["size"] = size(result)

	lengths = ncodeunits.(String.(result)) # This handles Symbols too
	g["lengths"] = lengths

	tot_length = sum(lengths)
	bytes = UInt8[]
	sizehint!(bytes, tot_length)
	for s in result
		append!(bytes, codeunits(String(s))) # This handles Symbols too
	end
	@assert length(bytes) == tot_length
	g["bytes"] = bytes
	nothing
end

cache_save(io, name, result::Array{String,N}) where N =
	_cache_save_string_array(io, name, "ArrayOfStrings", result)
cache_save(io, name, result::Array{Symbol,N}) where N =
	_cache_save_string_array(io, name, "ArrayOfSymbols", result)

function cache_save(io, name, result::Array{T,N}) where {T,N} # NB: Strings/Symbols are handled above
	# if store_eltype_inline(T) || isempty(result)
	if isbitstype(T) || isempty(result)
		# Rely on JLD2 for inlined eltypes - and to store type info for empty arrays
		io[name] = result
	elseif store_eltype_union(T)
		g = JLD2.Group(io, name)
		g["type"] = "ArrayUnion"
		g["size"] = size(result)

		ut = split_union_type(T)
		type_index = UInt8[findfirst(S->x isa S, ut) for x in result]
		g["type_index"] = type_index
		for (i,Ti) in enumerate(ut)
			part = Ti[result[k] for k in eachindex(result) if result[k] isa Ti]
			cache_save(g, string(i), part)
		end
	else
		# Save as a group
		g = JLD2.Group(io, name)
		g["type"] = "Array"
		g["size"] = size(result)
		for (ind,x) in pairs(result)
			cache_save(g, _index_to_string(ind), x)
		end
	end
	nothing
end
cache_save(io, name, result::ROArray{T,N}) where {T,N} = cache_save(io, name, parent(result))


function _cache_load_string_array(::Type{T}, cache::Cache, g, sz::NTuple{N,Int}) where {T,N}
	lengths = g["lengths"]::Array{Int,N}
	@assert length(lengths) == prod(sz)
	bytes = g["bytes"]::Vector{UInt8}
	out = Array{T,N}(undef, sz)
	pos = 1
	for (i,len) in enumerate(lengths)
		out[i] = T(String(@views(bytes[pos:pos+len-1]))) # Using StringViews.jl we could get rid of an allocation when creating Symbols here
		pos += len
	end
	out
end
function cache_load(cache::Cache, ::Val{:ArrayOfStrings}, g)
	sz = g["size"]
	_cache_load_string_array(String, cache, g, sz)
end
function cache_load(cache::Cache, ::Val{:ArrayOfSymbols}, g)
	sz = g["size"]
	_cache_load_string_array(Symbol, cache, g, sz)
end



function cache_load_array(cache, g, sz::NTuple{N,Int}) where N
	# a = [cache_load(cache, g, _index_to_string(ind)) for ind in CartesianIndices(sz)]
	# deduplicate!(cache.deduplicator, a; transfer_ownership=true)
	a = [cache_load(cache, g, _index_to_string(ind)) for ind in CartesianIndices(sz)]
	ReadOnlyArray(a)
end
function cache_load(cache::Cache, ::Val{:Array}, g)
	sz = g["size"]
	cache_load_array(cache, g, sz)
end


function _merge_union_parts(sz, type_index, parts::T) where T<:Tuple
	out = Array{Union{eltype.(fieldtypes(T))...}}(undef, sz)
	for i in 1:length(parts)
		out[type_index.==i] .= parts[i]
	end
	out
end
function cache_load_array_union(cache, g, sz::NTuple{N,Int}, type_index::Vector{UInt8}) where N
	n_types = maximum(type_index)
	parts = ntuple(i->parent(cache_load(cache, g, string(i))), n_types)
	_merge_union_parts(sz, type_index, parts)
end
function cache_load(cache::Cache, ::Val{:ArrayUnion}, g)
	sz = g["size"]
	type_index = g["type_index"]
	a = cache_load_array_union(cache, g, sz, type_index)
	ReadOnlyArray(a)
end




function cache_save(io, name, result::ROBitArray{N}) where N
	# Unwrap ROBitArray into BitArray and rely on JLD2 handling of the BitArray. This implicitly relies on BitArray internals, but we don't need to explicitly deal with them here...
	# We could consider using CustomStorage, but then we need some way to construct a BitArray from chunks and there is no public interface for that.
	io[name] = parent(result)
	nothing
end


function cache_save(io, name, result::T) where T<:NamedTuple
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "NamedTuple"
	g["keys"] = keys(result)
	for (i,x) in enumerate(result)
		cache_save(g, string(i), x)
	end
	nothing
end
function cache_load(cache::Cache, ::Val{:NamedTuple}, g)
	keys = g["keys"]
	NamedTuple(k=>cache_load(cache, g, string(i)) for (i,k) in enumerate(keys))
end


function cache_save(io, name, result::Dict{K,V}) where {K,V}
	# Save as a group of keys and values
	g = JLD2.Group(io, name)
	g["type"] = "Dict"
	cache_save(g, "keys", collect(keys(result)))
	cache_save(g, "values", collect(values(result)))
	nothing
end
function cache_load(cache::Cache, ::Val{:Dict}, g)
	keys = parent(cache_load(cache, g, "keys"))
	values = parent(cache_load(cache, g, "values"))
	# d = Dict(keys.=>values)
	# deduplicate!(cache.deduplicator, d; transfer_ownership=true)
	Dict(keys.=>values)
end


function cache_save(io, name, df::DataFrame)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "DataFrame"
	g["names"] = names(df)
	for (i,col) in enumerate(eachcol(df))
		cache_save(g, string(i), col)
	end
	nothing
end
function cache_load(cache::Cache, ::Val{:DataFrame}, g)
	names = g["names"]::Vector{String}
	named_cols = (name=>cache_load(cache, g, string(i)) for (i,name) in enumerate(names))
	# df = DataFrame(named_cols...; copycols=false)
	# deduplicate!(cache.deduplicator, df; transfer_ownership=true)
	DataFrame(named_cols...; copycols=false)
end



# Experimental CompoundResult support.
function cache_save(io, name, cr::CompoundResult)
	# Save as a group
	g = JLD2.Group(io, name)
	g["type"] = "CompoundResult"
	g["keys"] = parent(cr.keys)
	for (i,v) in pairs(cr.values)
		v isa CompoundResult && error("Nested CompoundResults are not (yet?) implemented.")
		cache_save(g, string(i), v)
	end
end
function cache_load(cache::Cache, ::Val{:CompoundResult}, g)
	error("Loading an entire CompoundResult is not allowed, a sub-result must be specified.")
end
function cache_load_compound_result_structure(io)
	@assert io["type"] == "CompoundResult"
	k = ReadOnlyVector(io["keys"])
	WeakCompoundResult(k)
end
function cache_load_subresult!(cache::Cache, cr::WeakCompoundResult, g, sub::String)
	@assert cr.keys == g["keys"]
	ind = findfirst(==(sub), cr.keys)
	x = cache_load(cache, g, string(ind))
	cr.values[ind] = deconstruct_weak_rec(x) # Store weakly in the Cache
	x
end





function _load_file(cache::Cache{K}, key::K, fp) where K
	jldopen(fp, "r") do io
		original_key = cache_load(cache, io, "key")
		@assert isequal(key, original_key) "Spec doesn't match cached spec, even though hashes are equal."
		x = cache_load(cache, io, "root")
		deduplicate!(cache.deduplicator, x; transfer_ownership=true)
	end
end

# Experimental CompoundResult support.
function _load_compound_result_structure(cache::Cache{K}, key::K, fp) where K
	jldopen(fp, "r") do io
		original_key = cache_load(cache, io, "key")
		@assert isequal(key, original_key) "Spec doesn't match cached spec, even though hashes are equal."
		cache_load_compound_result_structure(io["root"])
	end
end
function _load_subresult!(cache, cr, fp, sub)
	jldopen(fp, "r") do io
		x = cache_load_subresult!(cache, cr, io["root"], sub)
		deduplicate!(cache.deduplicator, x; transfer_ownership=true)
	end
end


# assumes deduplicate! has already been called on result
function _save_file(cache::Cache{K}, key::K, fp, result) where K
	isdir(cache.dir) || mkdir(cache.dir)
	jldopen(fp, "w"; compress=ZstdFilter()) do io # should we set compression level?
		cache_save(io, "key", key)
		cache_save(io, "root", result)
	end
end


function cache_get!(f, cache::Cache{K}, key::K; use_disk=nothing) where K
	if cache.dir === nothing
		use_disk = false
	else
		@assert use_disk isa Bool "Please specify use_disk::Bool."
	end
	use_disk::Bool # Probably not needed?

	# Check in-memory cache
	result = cache_mem_get(cache, key)
	result isa CompoundResult && throw(ArgumentError("Cannot retrieve CompoundResult directly from cache. You must specify sub-result(s) using cached(key,sub...)."))

	result !== NotValid() && return result

	# Check on-disk cache
	if use_disk
		fp = key2path(cache, key)
		if isfile(fp)
			result = _load_file(cache, key, fp) # This should deduplicate already
		end
	end


	if result === NotValid()
		result = f()
		result isa CompoundResult && throw(ArgumentError("Cannot retrieve CompoundResult directly from cache. You must specify sub-result(s) using cached(key,sub...)."))
		result = deduplicate!(cache.deduplicator, result; transfer_ownership=true)
		use_disk && !(result isa Exception) && _save_file(cache, key, fp, result)
	end

	cache_mem_set!(cache, key, result)
	return result
end

# This is experimental.
# TODO: simplify code
function cache_get_subresult!(f, cache::Cache{K}, key::K; use_disk=nothing, sub=nothing, return_keys::Bool=false) where K
	(sub===nothing) == (return_keys==false) && throw(ArgumentError("Either specify sub or set return_keys=true (but not both)."))
	@assert use_disk "CompoundResults are only available when use_disk=true"
	@assert cache.dir !== nothing

	# Check in-memory cache
	# cr = cache_mem_get(cache, key)
	cr = get(cache.mem, key, NotValid()) # Load without reconstructing

	if cr isa WeakCompoundResult
		return_keys && return get_keys(cr)

		# Return partial result if still valid
		# subresult = get_subresult(cr, sub; return_keys)
		subresult = get_subresult(cr, sub)
		subresult = reconstruct_weak_rec(subresult)
		subresult !== NotValid() && return subresult
	elseif cr isa Exception
		return cr
	elseif cr !== NotValid()
		throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))
	end

	# Check on-disk cache
	fp = key2path(cache, key)
	if isfile(fp)
		if cr === NotValid()
			cr = _load_compound_result_structure(cache, key, fp)
			# cache_mem_set!(cache, key, cr) # NB: This is directly from the Weak version
			cache.mem[key] = cr # Since we have loaded the Weak version, we shouldn't call deconstruct_weak_rec

			return_keys && return get_keys(cr)
			# return_keys && return get_subresult(cr, sub; return_keys)
		end
		return _load_subresult!(cache, cr, fp, sub)
	end

	# Sanity check
	@assert cr === NotValid() "CompoundResult found in in-mem Cache was not matched by file on disk."

	cr = f()
	cr isa Exception && return cr

	cr isa CompoundResult || throw(ArgumentError("Tried to retrieve sub-result from result that was not a CompoundResult."))
	cr = deduplicate!(cache.deduplicator, cr; transfer_ownership=true)
	_save_file(cache, key, fp, cr)
	cache_mem_set!(cache, key, cr)
	return_keys && return get_keys(cr)
	return get_subresult(cr, sub)
end
