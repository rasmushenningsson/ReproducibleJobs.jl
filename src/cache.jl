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
		isequal(sa, cached_sa) || @warn "Job specification did not match job specification in cache (possible cause, Regex within a Base.Fix2)."

		_cache_load_item(io, sub)
	end

	touch(fp) # update file timestamp (in case we want to remove old cached files later)
	value
end


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
		jldopen(fp, "w"; compress=ZstdFrameCompressor()) do io
			io["spec_args"] = spec_args
			_cache_save_item(io, value)
		end
	end
end


get_cache_key(ro::ReadOnly{SpecArgs}) = spec2path(get_cache(),ro), ro.value

function cache_load((fp,sa)::Tuple{String, SpecArgs}, sub)
	isfile(fp) ? _cache_load(fp, sa, sub) : nothing
end

function cache_save((fp,sa)::Tuple{String, SpecArgs}, value)
	@assert !isfile(fp)
	_cache_save(fp, sa, value)
end
