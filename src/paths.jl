"""
    TimestampedFilePath(path::String)

A file path wrapper that captures the file's modification time (`mtime`) at construction.
Used as a spec argument so that file changes invalidate cached computations.

See also [`ChecksummedFilePath`](@ref), [`checksummedfilepath_job`](@ref).
"""
struct TimestampedFilePath
	path::String
	timestamp::Float64
end
function TimestampedFilePath(path)
	st = stat(path)
	@assert isfile(st) "File not found: \"$path\"."
	TimestampedFilePath(path, mtime(st))
end

deduplicate_type(::Type{TimestampedFilePath}) = false
deconstruct_weak_rec(x::TimestampedFilePath) = x
reconstruct_weak_rec(x::TimestampedFilePath) = x

function cache_save(cache::Cache, io, name, x::TimestampedFilePath)
	io[name] = x # Rely on JLD2 standard handling for saving/loading
	nothing
end


function Base.show(io::IO, ts::TimestampedFilePath)
	print(io, '"', ts.path, '"')
	printstyled(io, '@', Dates.unix2datetime(ts.timestamp); color=:light_black)
end


"""
    ChecksummedFilePath(path::String)
    ChecksummedFilePath(ts::TimestampedFilePath)

A file path wrapper that captures the file's SHA-256 checksum. Equality is based solely on
the checksum, so cached results survive file renames or moves as long as the content is
unchanged.

See also [`TimestampedFilePath`](@ref), [`checksummedfilepath_job`](@ref).
"""
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


deduplicate_type(::Type{ChecksummedFilePath}) = false
deconstruct_weak_rec(x::ChecksummedFilePath) = x
reconstruct_weak_rec(x::ChecksummedFilePath) = x

function cache_save(cache::Cache, io, name, x::ChecksummedFilePath)
	io[name] = x # Rely on JLD2 standard handling for saving/loading
	nothing
end





function Base.string(x::ChecksummedFilePath)
	@assert mtime(x.path)==x.timestamp "File \"$(x.path)\" modified during analysis."
	string(x.path)
end
Base.show(io::IO, x::ChecksummedFilePath) = print(io, "ChecksummedFilePath(", x.checksum[1:min(6,end)], " \"", x.path, "\")")



"""
    checksummedfilepath_job(path; kwargs...) -> Job
    checksummedfilepath_job(ts::TimestampedFilePath; kwargs...) -> Job

Create a [`Job`](@ref) that computes and caches a [`ChecksummedFilePath`](@ref) from a file
path or [`TimestampedFilePath`](@ref). The result is prefetched to ensure that the hash of a spec
containing a `ChecksummedFilePath` only depends on the file checksum and not the current path or
modification time.

!!! warning
	Must be used by all specs referring to files! Otherwise, changing the file on disk will not
	result in recomputation.

See also [`ChecksummedFilePath`](@ref), [`TimestampedFilePath`](@ref).
"""
checksummedfilepath_job(ts::TimestampedFilePath; kwargs...) =
	prefetched(cached(create_job(checksummedfilepath, ts; kwargs..., __version=v"0.1.0")))
checksummedfilepath_job(fp::AbstractString; kwargs...) =
	checksummedfilepath_job(TimestampedFilePath(fp); kwargs...)

# checksummedfilepath_job(fp; kwargs...) = Job(checksummedfilepath_job(fp; kwargs...))
