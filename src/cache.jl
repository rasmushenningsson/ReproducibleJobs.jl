struct Cache
	dir::String
end

let cache = Cache(@get_scratch!("CacheBySpec"))
	global get_cache() = cache
end

spec2path(cache::Cache, spec::Spec) = joinpath(cache.dir, string(get_hash(spec),".jld2"))


function cache_load(cache::Cache, fp, spec::Spec)
	@info "Loading $(get_versioned_function(spec)) from cache"
	d = load(fp)
	cached_spec = d["spec"]
	@assert spec == cached_spec "Job specification did not match job specification in cache" # TODO: Decide what to do on failure - delete the file???
	return d["value"]
end


Base.haskey(cache::Cache, spec::Spec) = isfile(spec2path(cache, spec))
function Base.get(cache::Cache, spec::Spec, default::Nothing)
	fp = spec2path(cache, spec)
	isfile(fp) && return cache_load(cache, fp, spec)
	return default
end

function Base.get!(f, cache::Cache, spec::Spec)
	fp = spec2path(cache, spec)
	isfile(fp) && return cache_load(cache, fp, spec)

	value = f()
	jldsave(fp; spec, value, compress=true)
	return value
end


cache_haskey(spec::Spec) = haskey(get_cache(), spec)
cache_get(spec, default) = get(get_cache(), spec, default)
cache_get!(f, spec) = get!(f, get_cache(), spec)
