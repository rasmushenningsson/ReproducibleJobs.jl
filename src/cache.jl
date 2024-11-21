struct Cache
	dir::String
end

let cache = Cache(@get_scratch!("CacheBySpec"))
	global get_cache() = cache
end



spec2path(cache::Cache, ro::ReadOnly{SpecArgs}) = joinpath(cache.dir, string(get_hash(ro),".jld2"))
spec2path(cache::Cache, spec::Spec) = spec2path(cache, spec.ro)



function _cache_load(fp, sa::SpecArgs)
	@info "Loading $(get_versioned_function(sa)) from cache"
	d = load(fp)
	cached_sa = d["spec_args"]
	@assert sa == cached_sa "Job specification did not match job specification in cache" # TODO: Decide what to do on failure - delete the file???
	touch(fp) # update file timestamp (in case we want to remove old cached files later)
	return d["value"]
end
_cache_load(fp, spec::Spec) = _cache_load(fp, spec.ro.value)

_cache_save(fp, spec_args::SpecArgs, value) = jldsave(fp, true; spec_args, value) # compress=true
_cache_save(fp, spec::Spec, value) = _cache_save(fp, spec.ro.value, value)


Base.haskey(cache::Cache, spec::Spec) = isfile(spec2path(cache, spec))
function Base.get(cache::Cache, spec::Spec, default::Nothing)
	fp = spec2path(cache, spec)
	isfile(fp) && return _cache_load(fp, spec)
	return default
end

function Base.get!(f, cache::Cache, spec::Spec)
	fp = spec2path(cache, spec)
	isfile(fp) && return _cache_load(fp, spec)
	value = f()
	_cache_save(fp, spec, value)
	return value
end

function cache_insert!(cache::Cache, spec::Spec, value)
	fp = spec2path(cache, spec)
	isfile(fp) && error("cache_insert! expects a spec that is not already in the cache. Got $(get_versioned_function(spec)) with hash $(spec.ro.h).")
	_cache_save(fp, spec, value)
	return value
end


cache_haskey(spec::Spec) = haskey(get_cache(), spec)
cache_get(spec, default) = get(get_cache(), spec, default)
cache_get!(f, spec) = get!(f, get_cache(), spec)
cache_insert!(spec, value) = cache_insert!(get_cache(), spec, value)
