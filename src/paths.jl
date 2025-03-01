struct TimestampedFilePath
	path::String
	timestamp::Float64
end
TimestampedFilePath(path) = (@assert isfile(path); TimestampedFilePath(path, mtime(path)))

function Base.show(io::IO, ts::TimestampedFilePath)
	print(io, '"', ts.path, '"')
	printstyled(io, '@', Dates.unix2datetime(ts.timestamp); color=:light_black)
end


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

Base.:(==)(a::ChecksummedFilePath, b::ChecksummedFilePath) = a.checksum == b.checksum






function Base.string(x::ChecksummedFilePath)
	@assert mtime(x.path)==x.timestamp "File \"$(x.path)\" modified during analysis."
	string(x.path)
end
Base.show(io::IO, x::ChecksummedFilePath) = print(io, "ChecksummedFilePath(", x.checksum[1:min(6,end)], " \"", x.path, "\")")



checksummedfilepath_spec(ts::TimestampedFilePath; kwargs...) =
	create_spec(checksummedfilepath, ts; use_cache=true, prefetch=true, kwargs..., __version=v"0.1.0")
checksummedfilepath_spec(fp::AbstractString; kwargs...) =
	checksummedfilepath_spec(TimestampedFilePath(fp); kwargs...)

checksummedfilepath_job(fp; kwargs...) = Job(checksummedfilepath_spec(fp; kwargs...))


copy_arg(ts::TimestampedFilePath) = ts # Already managed, no need to copy
