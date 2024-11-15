struct TimestampedFilePath{T}
	path::T
	timestamp::Float64
end
TimestampedFilePath(path) = (@assert isfile(path); TimestampedFilePath(path, mtime(path)))

timestampedfilepath(path) = TimestampedFilePath(path)
# version(::TimestampedFilePath) = v"1.0.0"




struct ChecksummedFilePath{T}
	path::T
	timestamp::Float64
	checksum::String
end
function ChecksummedFilePath(x::TimestampedFilePath)
	t = mtime(x.path)
	@assert t==x.timestamp "File \"$(x.path)\" modified during analysis."
	checksum = bytes2hex(open(sha256,x.path))
	@show checksum
	ChecksummedFilePath(x.path, t, checksum)
end
ChecksummedFilePath(path) = ChecksummedFilePath(TimestampedFilePath(path))

checksummedfilepath(path) = ChecksummedFilePath(path)
# version(::ChecksummedFilePath) = v"1.0.0"



StableHashTraits.transformer(::Type{<:ChecksummedFilePath}) = StableHashTraits.Transformer(pick_fields(:checksum))



function Base.string(x::ChecksummedFilePath)
	@assert mtime(x.path)==x.timestamp "File \"$(x.path)\" modified during analysis."
	string(x.path)
end
Base.show(io::IO, x::ChecksummedFilePath) = print(io, "ChecksummedFilePath(", x.checksum[1:min(6,end)], " \"", x.path, "\")")



timestampedfilepath_job(fp; kwargs...) =
	Job(create_spec(fp; use_cache=false, __versionedfunction=VersionedFunction(timestampedfilepath,v"0.1.0"), kwargs...))

function checksummedfilepath_job(fp; kwargs...)
	ts = timestampedfilepath_job(fp)
	Job(create_spec(ts; use_cache=true, __versionedfunction=VersionedFunction(checksummedfilepath,v"0.1.0"), kwargs...))
end
