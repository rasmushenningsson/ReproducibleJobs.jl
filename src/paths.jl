# NB: If we change how TimestampedFilePath works, we must change its stable_hash too.
struct TimestampedFilePath
	path::String
	timestamp::Float64
end
function TimestampedFilePath(path)
	st = stat(path)
	@assert isfile(st) "File not found: \"$path\"."
	TimestampedFilePath(st, mtime(st))
end

Deduplicators.deduplicate_type(::Type{TimestampedFilePath}) = false
Deduplicators.deconstruct_weak_rec(x::TimestampedFilePath) = x
Deduplicators.reconstruct_weak_rec(x::TimestampedFilePath) = x

function Deduplicators.cache_save(io, name, x::TimestampedFilePath)
	io[name] = x # Rely on JLD2 standard handling for saving/loading
	nothing
end


function Base.show(io::IO, ts::TimestampedFilePath)
	print(io, '"', ts.path, '"')
	printstyled(io, '@', Dates.unix2datetime(ts.timestamp); color=:light_black)
end


# NB: If we change how ChecksummedFilePath works, we must change its stable_hash too.
struct ChecksummedFilePath
	path::String
	timestamp::Float64
	checksum::String
end
function ChecksummedFilePath(x::TimestampedFilePath)
	t = mtime(x.path)
	@assert t==x.timestamp "File \"$(x.path)\" modified during analysis."
	checksum = bytes2hex(open(sha256,x.path))
	ChecksummedFilePath(x.path, t, checksum)
end
ChecksummedFilePath(path::String) = ChecksummedFilePath(TimestampedFilePath(path))

checksummedfilepath(path) = ChecksummedFilePath(path)


StableHashTraits.transformer(::Type{<:ChecksummedFilePath}) = StableHashTraits.Transformer(pick_fields(:checksum))

Base.isequal(a::ChecksummedFilePath, b::ChecksummedFilePath) = isequal(a.checksum, b.checksum) # This allows us to compare with old specs saved to disk - even if the file moved change timestamp.


Deduplicators.deduplicate_type(::Type{ChecksummedFilePath}) = false
Deduplicators.deconstruct_weak_rec(x::ChecksummedFilePath) = x
Deduplicators.reconstruct_weak_rec(x::ChecksummedFilePath) = x

function Deduplicators.cache_save(io, name, x::ChecksummedFilePath)
	io[name] = x # Rely on JLD2 standard handling for saving/loading
	nothing
end





function Base.string(x::ChecksummedFilePath)
	@assert mtime(x.path)==x.timestamp "File \"$(x.path)\" modified during analysis."
	string(x.path)
end
Base.show(io::IO, x::ChecksummedFilePath) = print(io, "ChecksummedFilePath(", x.checksum[1:min(6,end)], " \"", x.path, "\")")



checksummedfilepath_spec(ts::TimestampedFilePath; kwargs...) =
	prefetched(cached(create_spec(checksummedfilepath, ts; kwargs..., __version=v"0.1.0")))
checksummedfilepath_spec(fp::AbstractString; kwargs...) =
	checksummedfilepath_spec(TimestampedFilePath(fp); kwargs...)

# checksummedfilepath_job(fp; kwargs...) = Job(checksummedfilepath_spec(fp; kwargs...))
