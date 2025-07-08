struct Cache
	dir::String
end

let cache = Cache(@get_scratch!("ReproducibleJobs"))
	global get_cache() = cache
end



spec2path(cache::Cache, ro::ReadOnly{SpecArgs}) = joinpath(cache.dir, string(get_hash(ro),".jld2"))



function _cache_load(fp, sa::SpecArgs)
	@info "Loading $(sa.f) from cache"
	d = load(fp)
	cached_sa = d["spec_args"]

	# TODO: handle this better...
	#       perhaps by wrapping Fix1/Fix2 in our own type internally...
	sa == cached_sa || @warn "Job specification did not match job specification in cache (likely cause, Regex within a Base.Fix2)."

	touch(fp) # update file timestamp (in case we want to remove old cached files later)
	return d["value"]
end
_cache_load(fp, ro::ReadOnly{SpecArgs}) = _cache_load(fp, ro.value)

# _cache_save(fp, spec_args::SpecArgs, value) = jldsave(fp, true; spec_args, value) # compress=true - using CodecZlib
function _cache_save(fp, spec_args::SpecArgs, value)
	if !(value isa ProcessingException)
		jldsave(fp, ZstdFrameCompressor(); spec_args, value) # compress with Zstd - Default compression level is probably fine.
	end
end
_cache_save(fp, ro::ReadOnly{SpecArgs}, value) = _cache_save(fp, ro.value, value)


Base.haskey(cache::Cache, ro::ReadOnly{SpecArgs}) = isfile(spec2path(cache, ro))
function Base.get(cache::Cache, ro::ReadOnly{SpecArgs}, default::Nothing)
	fp = spec2path(cache, ro)
	isfile(fp) && return _cache_load(fp, ro)
	return default
end

function Base.get!(f, cache::Cache, ro::ReadOnly{SpecArgs})
	fp = spec2path(cache, ro)
	isfile(fp) && return _cache_load(fp, ro)
	value = f()
	_cache_save(fp, ro, value)
	return value
end

function cache_insert!(cache::Cache, ro::ReadOnly{SpecArgs}, value)
	fp = spec2path(cache, ro)
	isfile(fp) && error("cache_insert! expects a spec that is not already in the cache. Got $(ro.value.f) with hash $(ro.h).")
	_cache_save(fp, ro, value)
	return value
end


cache_haskey(ro::ReadOnly{SpecArgs}) = haskey(get_cache(), ro)
cache_get(ro, default) = get(get_cache(), ro, default)
cache_get!(f, ro) = get!(f, get_cache(), ro)
cache_insert!(ro, value) = cache_insert!(get_cache(), ro, value)
