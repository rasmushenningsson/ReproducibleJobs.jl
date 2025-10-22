struct Cache
	dir::String
end


spec2path(cache::Cache, ro::ReadOnly{SpecArgs}) = joinpath(cache.dir, string(get_hash(ro),".jld2"))


function _cache_load_item(io, sub)
	if sub === nothing || isempty(sub)
		return io["value"]
	else
		children = io["children"]
		child = children[sub[1]]
		_cache_load_item(child, @view(sub[2:end]))
	end
end

function _cache_load(fp, sa::SpecArgs, sub)
	if sub === nothing
		@info "Loading $(sa.f) from cache"
	else
		@info "Loading $(*(string(sa.f), string.('.',sub)...)) from cache"
	end

	value = jldopen(fp, "r") do io
		cached_sa = io["spec_args"]

		# TODO: Avoid calling this many times for different sub
		# TODO: handle this better...
		#       perhaps by wrapping Fix1/Fix2 in our own type internally...
		#       or by using a custom comparison function...
		# sa == cached_sa || @warn "Job specification did not match job specification in cache (possible cause, Regex within a Base.Fix2)."
		isequal(sa, cached_sa) || @warn "Job specification did not match job specification in cache (possible cause, Regex within a Base.Fix2)."

		_cache_load_item(io, sub)
	end

	touch(fp) # update file timestamp (in case we want to remove old cached files later)
	value
end


# function _cache_load(fp, sa::SpecArgs)
# 	@info "Loading $(sa.f) from cache"
# 	d = load(fp)
# 	cached_sa = d["spec_args"]

# 	# TODO: handle this better...
# 	#       perhaps by wrapping Fix1/Fix2 in our own type internally...
# 	# sa == cached_sa || @warn "Job specification did not match job specification in cache (possible cause, Regex within a Base.Fix2)."
# 	isequal(sa, cached_sa) || @warn "Job specification did not match job specification in cache (possible cause, Regex within a Base.Fix2)."

# 	touch(fp) # update file timestamp (in case we want to remove old cached files later)
# 	return d["value"]
# end
# _cache_load(fp, ro::ReadOnly{SpecArgs}, sub) = _cache_load(fp, ro.value, sub)


function _cache_save_item(io, value)
	io["value"] = value
end
function _cache_save_item(io, cr::CompoundResult)
	io["value"] = first.(cr.children)
	children = JLD2.Group(io, "children")
	for (k,v) in cr.children
		child = JLD2.Group(children, k)
		_cache_save_item(child, v)
	end
end


function _cache_save(fp, spec_args::SpecArgs, value)
	if !(value isa ProcessingException)
		# jldsave(fp, ZstdFrameCompressor(); spec_args, value) # compress with Zstd - Default compression level is probably fine.

		jldopen(fp, "w"; compress=ZstdFrameCompressor()) do io
			io["spec_args"] = spec_args
			_cache_save_item(io, value)
		end
	end
end
# _cache_save(fp, ro::ReadOnly{SpecArgs}, value) = _cache_save(fp, ro.value, value)


# Base.haskey(cache::Cache, ro::ReadOnly{SpecArgs}) = isfile(spec2path(cache, ro))

# function Base.get(cache::Cache, ro::ReadOnly{SpecArgs}, default::Nothing)
# 	fp = spec2path(cache, ro)
# 	isfile(fp) && return _cache_load(fp, ro, String[]) # TODO: support sub
# 	return default
# end

# function Base.get!(f, cache::Cache, ro::ReadOnly{SpecArgs})
# 	fp = spec2path(cache, ro)
# 	isfile(fp) && return _cache_load(fp, ro, String[]) # TODO: support sub
# 	value = f()
# 	_cache_save(fp, ro, value)
# 	return value
# end

# function cache_insert!(cache::Cache, ro::ReadOnly{SpecArgs}, value)
# 	fp = spec2path(cache, ro)
# 	isfile(fp) && error("cache_insert! expects a spec that is not already in the cache. Got $(ro.value.f) with hash $(ro.h).")
# 	_cache_save(fp, ro, value)
# 	return value
# end


# cache_haskey(ro::ReadOnly{SpecArgs}) = haskey(get_cache(), ro)
# cache_get(ro, default) = get(get_cache(), ro, default)
# cache_get!(f, ro) = get!(f, get_cache(), ro)
# cache_insert!(ro, value) = cache_insert!(get_cache(), ro, value)


get_cache_key(ro::ReadOnly{SpecArgs}) = spec2path(get_cache(),ro), ro.value

function cache_load((fp,sa)::Tuple{String, SpecArgs}, sub)
	isfile(fp) ? _cache_load(fp, sa, sub) : nothing
end

function cache_save((fp,sa)::Tuple{String, SpecArgs}, value)
	@assert !isfile(fp)
	_cache_save(fp, sa, value)
end


# WIP
# function cache_get!(f, ro, sub)
# 	cache = get_cache()
# 	fp = spec2path(cache, ro)
# 	isfile(fp) && return _cache_load(fp, ro, sub)
# 	value = f()
# 	_cache_save(fp, ro, value)
# 	return value
# end
