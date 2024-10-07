module CacheBySpec

using StableHashTraits

export
	Deduplicator,
	deduplicate!

include("read_only.jl")
include("deduplicator.jl")

end
